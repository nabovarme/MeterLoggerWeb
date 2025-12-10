#!/usr/bin/perl

use strict;
use warnings;
use Net::SMTP;
use threads;
use threads::shared;
use Time::HiRes qw(time);

$| = 1;  # disable STDOUT buffering

# Watch containers
my @containers = ("postfix", "smsd");

# ---- Error patterns ----
my @error_patterns = (
	qr/dsn=4\.\d\.\d/i,
	qr/status=deferred/i,
	qr/host .* said:/i,
	qr/ERROR/i,
	qr/failed to connect/i,
	qr/connection refused/i,
	qr/Failed to init session/i
);

# ---- SMTP config ----
my $smtp_host = $ENV{SMTP_HOST}   or die "Missing SMTP_HOST env variable\n";
my $smtp_port = $ENV{SMTP_PORT}   || 587;
my $smtp_user = $ENV{SMTP_USER}   || '';
my $smtp_pass = $ENV{SMTP_PASSWORD} || '';
my $from_email = $ENV{FROM_EMAIL} || $smtp_user;
my $to_email   = $ENV{TO_EMAIL} or die "Missing TO_EMAIL env variable\n";
my @to_list    = split /[\s,]+/, $to_email;

# Shared hash to prevent multiple emails
my %sent_alerts :shared;

# ---- Send email ----
sub send_email {
	my ($msg) = @_;
	{
		lock(%sent_alerts);
		return if $sent_alerts{$msg};
		$sent_alerts{$msg} = 1;
	}

	# Send one email per recipient
	foreach my $recipient (@to_list) {
		my $smtp = Net::SMTP->new(
			$smtp_host,
			Port            => $smtp_port,
			Timeout         => 20,
			Debug           => 0,
			SSL_verify_mode => 0,
		) or do { warn "SMTP connect failed\n"; next; };

		eval { $smtp->starttls(); };

		# Authenticate if credentials provided
		if ($smtp_user && $smtp_pass) {
			unless ($smtp->auth($smtp_user, $smtp_pass)) {
				warn "SMTP auth failed\n";
				$smtp->quit;
				next;
			}
		} else {
			# Warn if credentials are missing and you expected them
			warn "SMTP credentials not provided, skipping auth\n";
		}

		# Set sender and recipient
		$smtp->mail($from_email);
		$smtp->to($recipient);

		# Send email with
		$smtp->data();
		$smtp->datasend("To: $recipient\n");
		$smtp->datasend("From: $from_email\n");
		$smtp->datasend("Subject: Container alert detected\n");
		$smtp->datasend("\n$msg\n");
		$smtp->dataend();

		# Close SMTP session
		$smtp->quit();

		print "Email sent to $recipient: $msg\n";
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

			foreach my $pattern (@error_patterns) {
				if ($line =~ $pattern) {
					print "Detected error in $container: $line\n";
					send_email("$container: $line");
					last;
				}
			}
		}

		warn "docker logs stream ended for $container — reconnecting in 5 sec...\n";
		sleep 5;
	}
}

# Start a thread for each container
my @threads;
foreach my $container (@containers) {
	push @threads, threads->create(\&watch_container, $container);
}

# Wait for all threads (runs indefinitely)
$_->join for @threads;
