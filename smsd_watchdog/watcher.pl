#!/usr/bin/perl

use strict;
use warnings;
use utf8;
use Net::SMTP;
use threads;
use threads::shared;
use Time::HiRes qw(time);
use Email::MIME;
use Encode qw(decode encode);

use Nabovarme::Utils;

$| = 1;  # disable STDOUT buffering

# Make sure STDOUT and STDERR handles UTF-8
binmode(STDOUT, ":encoding(UTF-8)");
binmode(STDERR, ":encoding(UTF-8)");

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
my $smtp_host  = $ENV{SMTP_HOST}   or log_die("Missing SMTP_HOST env variable", {-no_script_name => 1, -custom_tag => 'watcher' });
my $smtp_port  = $ENV{SMTP_PORT}   || 587;
my $smtp_user  = $ENV{SMTP_USER}   || '';
my $smtp_pass  = $ENV{SMTP_PASSWORD} || '';
my $from_email = $ENV{FROM_EMAIL} || $smtp_user;
my $to_email   = $ENV{TO_EMAIL}   or log_die("Missing TO_EMAIL env variable", {-no_script_name => 1, -custom_tag => 'watcher' });
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
	log_info("Dedup reset", {-no_script_name => 1, -custom_tag => $container });
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
		) or do { log_warn("SMTP connect failed", {-no_script_name => 1, -custom_tag => $container }); next; };

		eval { $smtp->starttls(); };

		if ($smtp_user && $smtp_pass) {
			unless ($smtp->auth($smtp_user, $smtp_pass)) {
				log_warn("SMTP auth failed", {-no_script_name => 1, -custom_tag => $container });
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

		log_info("Recovery summary email sent to $recipient", {-no_script_name => 1, -custom_tag => $container });
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
		) or do { log_warn("SMTP connect failed", {-no_script_name => 1, -custom_tag => $container }); next; };

		eval { $smtp->starttls(); };

		if ($smtp_user && $smtp_pass) {
			unless ($smtp->auth($smtp_user, $smtp_pass)) {
				log_warn("SMTP auth failed", {-no_script_name => 1, -custom_tag => $container });
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

		log_info("Error alert sent to $recipient: $msg", {-no_script_name => 1, -custom_tag => $container });
	}
}

# ---- Watch docker logs in threads ----
sub watch_container {
	my ($container) = @_;

	while (1) {
		my $since_time = `date -u +%Y-%m-%dT%H:%M:%S`;
		chomp $since_time;
		log_info("Watching logs from container since $since_time", {-no_script_name => 1, -custom_tag => $container });

		open(my $fh, "-|", "docker logs -f --since $since_time $container 2>&1")
			or do { log_warn("Cannot run docker logs: $!", {-no_script_name => 1, -custom_tag => $container }); sleep 5; next; };

		while (my $line = <$fh>) {
			chomp $line;

			# Decode from UTF-8 if necessary
			$line = decode('UTF-8', $line, Encode::FB_CROAK);

			# Trim whitespace
			$line =~ s/^\s+|\s+$//g;

			# Remove any prepending [XXX] or [XXX] [YYY]
			$line =~ s/^(?:\[[^\]]+\]\s*){1,2}//;

			# Check for errors
			foreach my $pattern (@{ $error_patterns{$container} || [] }) {
				if ($line =~ $pattern) {
					log_info("Detected error in line $line", {-no_script_name => 1, -custom_tag => $container });
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

		log_warn("docker logs ended for $container — reconnecting in 5 sec...", {-no_script_name => 1, -custom_tag => $container });
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
