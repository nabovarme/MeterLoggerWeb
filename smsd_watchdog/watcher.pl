#!/usr/bin/perl

use strict;
use warnings;
use Net::SMTP;
use threads;
use threads::shared;
use Time::HiRes qw(time);
use Email::MIME;
use Encode qw(encode);

$| = 1;  # disable STDOUT buffering

# Watch containers
my @containers = ("postfix", "smsd");

# ---- Error patterns ----
my %error_patterns = (
	smsd    => [
		qr/Failed to init session/i,
		qr/connection refused/i,
		qr/ERROR/i
	],
	postfix => [
		qr/dsn=4\.\d\.\d/i,
		qr/status=deferred/i,
		qr/host .* said:/i
	],
);

# ---- Recovery patterns ----
my %reset_patterns = (
	smsd    => [ qr/Session initialized successfully/i ],
	postfix => [ 
		qr/postfix\/master\[\d+\]: daemon started/i,
		qr/dsn=2\.0\.0/i
	],
);

# ---- SMTP config ----
my $smtp_host  = $ENV{SMTP_HOST}   or die "Missing SMTP_HOST env variable\n";
my $smtp_port  = $ENV{SMTP_PORT}   || 587;
my $smtp_user  = $ENV{SMTP_USER}   || '';
my $smtp_pass  = $ENV{SMTP_PASSWORD} || '';
my $from_email = $ENV{FROM_EMAIL} || $smtp_user;
my $to_email   = $ENV{TO_EMAIL}   or die "Missing TO_EMAIL env variable\n";
my @to_list    = split /[\s,]+/, $to_email;

# Shared dedupe storage and history using flat keys
my %sent_alerts :shared;
my %error_history :shared;
my %service_up :shared;       # Track if container is currently up
my %has_error :shared;        # Track if container has ever reported error
my %boot_done :shared;        # Track if first boot completed

# ---- Clear dedupe on recovery ----
sub clear_dedupe {
	my ($container) = @_;
	lock(%sent_alerts);
	foreach my $key (keys %sent_alerts) {
		delete $sent_alerts{$key} if $key =~ /^\Q$container\E:/;
	}
	foreach my $key (keys %error_history) {
		delete $error_history{$key} if $key =~ /^\Q$container\E:/;
	}
	print "Dedup reset for $container\n";
}

# ---- Send recovery summary email ----
sub send_recovery_email {
	my ($container) = @_;

	# Only send recovery if container previously had errors
	lock(%has_error);
	return unless $has_error{$container};
	
	my $summary = "";
	my @errors;
	lock(%error_history);
	foreach my $key (keys %error_history) {
		if ($key =~ /^\Q$container\E:/) {
			push @errors, $key;
		}
	}
	if (@errors) {
		$summary .= "The following unique errors occurred before recovery:\n\n";
		foreach my $err (@errors) {
			$err =~ s/^\Q$container\E://; # strip container prefix
			$summary .= "- $err\n";
		}
	} else {
		$summary = "Service restored with no recorded error backlog.\n";
	}

	# Skip recovery emails on first boot
	lock(%boot_done);
	return unless $boot_done{$container};

	my $utf8_body = encode("UTF-8", "$container is now operational.\n\n$summary\n");

	# Send one recovery email per recipient
	foreach my $recipient (@to_list) {

		my $email = Email::MIME->create(
			header_str => [
				From    => $from_email,
				To      => $recipient,
				Subject => "$container service restored",
			],
			attributes => { encoding => 'quoted-printable', charset => 'UTF-8' },
			body => $utf8_body,
		);

		my $smtp = Net::SMTP->new(
			$smtp_host,
			Port            => $smtp_port,
			Timeout         => 20,
			Debug           => 0,
			SSL_verify_mode => 0,
		) or do { warn "SMTP connect failed\n"; next; };

		eval { $smtp->starttls(); };

		if ($smtp_user && $smtp_pass) {
			unless ($smtp->auth($smtp_user, $smtp_pass)) {
				warn "SMTP auth failed\n";
				$smtp->quit;
				next;
			}
		}

		$smtp->mail($from_email);
		$smtp->to($recipient);

		$smtp->data();
		$smtp->datasend($email->as_string);
		$smtp->dataend();

		$smtp->quit();

		print "Recovery summary email sent to $recipient for $container\n";
	}

	# Reset error flag after sending recovery
	lock(%has_error);
	$has_error{$container} = 0;
}

# ---- Send alert email ----
sub send_email {
	my ($msg, $container, $pattern) = @_;

	my $core = "$pattern";
	my $flat_key = "$container:$core";

	# Store unique error pattern for later summary
	lock(%error_history);
	$error_history{$flat_key} = 1;

	lock(%sent_alerts);
	return if $sent_alerts{$flat_key};
	$sent_alerts{$flat_key} = 1;

	# Mark service as down and set error flag
	lock(%service_up);
	$service_up{$container} = 0;
	lock(%has_error);
	$has_error{$container} = 1;

	# Mark boot done
	lock(%boot_done);
	$boot_done{$container} = 1;

	my $utf8_body = encode("UTF-8", $msg);

	# Send one email per recipient
	foreach my $recipient (@to_list) {

		my $email = Email::MIME->create(
			header_str => [
				From    => $from_email,
				To      => $recipient,
				Subject => "$container alert detected",
			],
			attributes => { encoding => 'quoted-printable', charset => 'UTF-8' },
			body => $utf8_body,
		);

		my $smtp = Net::SMTP->new(
			$smtp_host,
			Port            => $smtp_port,
			Timeout         => 20,
			Debug           => 0,
			SSL_verify_mode => 0,
		) or do { warn "SMTP connect failed\n"; next; };

		eval { $smtp->starttls(); };

		if ($smtp_user && $smtp_pass) {
			unless ($smtp->auth($smtp_user, $smtp_pass)) {
				warn "SMTP auth failed\n";
				$smtp->quit;
				next;
			}
		}

		$smtp->mail($from_email);
		$smtp->to($recipient);

		$smtp->data();
		$smtp->datasend($email->as_string);
		$smtp->dataend();

		$smtp->quit();

		print "Error alert sent to $recipient: $msg\n";
	}
}

# ---- Watch docker logs in threads ----
sub watch_container {
	my ($container) = @_;

	while (1) {
		my $since_time = `date -u +%Y-%m-%dT%H:%M:%S`;
		chomp $since_time;
		print "Watching logs from container: $container since $since_time\n";

		open(my $fh, "-|", "docker logs -f --since $since_time $container 2>&1")
			or do { warn "Cannot run docker logs: $!\n"; sleep 5; next; };

		while (my $line = <$fh>) {
			chomp $line;
			$line =~ s/^\s+|\s+$//g;

			# Check for errors
			foreach my $pattern (@{ $error_patterns{$container} || [] }) {
				if ($line =~ $pattern) {
					print "Detected error in $container: $line\n";
					send_email("$container: $line", $container, $pattern);
					last;
				}
			}

			# Check for recovery lines
			foreach my $reset (@{ $reset_patterns{$container} || [] }) {
				if ($line =~ $reset) {
					lock(%service_up);
					unless ($service_up{$container}) {
						clear_dedupe($container);
						send_recovery_email($container);
						$service_up{$container} = 1;
					}
					last;
				}
			}
		}

		warn "docker logs ended for $container — reconnecting in 5 sec...\n";
		sleep 5;
	}
}

# Start a thread for each container
my @threads;
foreach my $container (@containers) {
	push @threads, threads->create(\&watch_container, $container);
}

# Wait indefinitely
$_->join for @threads;
