#!/usr/bin/perl

use strict;
use warnings;
use Net::SMTP;

$| = 1;  # disable STDOUT buffering

my $container_name = "smsd";

# Watch for registration errors AND SMS sending failures
my @error_patterns = (
	qr/MODEM IS NOT REGISTERED/i,
	qr/Modem is not registered to the network/i,
	qr/FAILED/i,
	qr/REJECTED/i,
	qr/SENDING FAILED/i,
	qr/CMS ERROR/i,
	qr/CME ERROR/i,
	qr/Message not sent/i,
	qr/Giving up/i,
	qr/Killed by signal/i,
	qr/Couldn't open serial port/
);

# ---- SMTP config ----
my $smtp_host = $ENV{SMTP_SERVER}	|| 'smtp.example.com';
my $smtp_port = $ENV{SMTP_PORT}		|| 587;   # STARTTLS port
my $smtp_user = $ENV{SMTP_USER}		|| 'user@example.com';
my $smtp_pass = $ENV{SMTP_PASSWORD}	|| 'password';
my $to_email  = $ENV{TO_EMAIL}		|| 'alert@example.com';

# Prevent multiple emails
my $alert_sent = 0;

# ---- Send single email ----
sub send_email_once {
	my ($msg) = @_;
	return if $alert_sent;

# Connect to SMTP server
	# Note: if connecting via IP, STARTTLS will fail certificate verification.
	# Setting SSL_verify_mode => 0 disables verification (insecure), only use if you trust the network.
	my $smtp = Net::SMTP->new(
		$smtp_host,
		Port    => $smtp_port,
		Timeout => 20,
		Debug   => 0,
		SSL_verify_mode => 0,  # WARNING: disables TLS certificate verification
	) or do {
		warn "SMTP connect failed\n";
		return;
	};

	# Try STARTTLS if supported (optional but preferred)
	eval { $smtp->starttls(); };

	unless ($smtp->auth($smtp_user, $smtp_pass)) {
		warn "SMTP auth failed\n";
		return;
	}

	$smtp->mail($smtp_user);
	$smtp->to($to_email);

	$smtp->data();
	$smtp->datasend("To: $to_email\n");
	$smtp->datasend("From: $smtp_user\n");
	$smtp->datasend("Subject: Modem/SMS alert detected\n");
	$smtp->datasend("\n$msg\n");
	$smtp->dataend();
	$smtp->quit();

	print "Email sent: $msg\n";
	$alert_sent = 1;
}

# ---- Toggle modem power with Docker stop/start ----
sub toggle_modem_power_with_container_restart {
	print "Stopping $container_name container...\n";
	system("docker compose stop $container_name") == 0
		or warn "Failed to stop $container_name\n";

	print "Toggling USB power...\n";
	system("uhubctl -l 3-1 -p 1 -a off && sleep 2 && uhubctl -l 3-1 -p 1 -a on") == 0
		or warn "Failed to toggle modem power\n";

	print "Starting $container_name container...\n";
	system("docker compose start $container_name") == 0
		or warn "Failed to start $container_name\n";

	print "Modem reset completed.\n";
}

# -------- Watch docker logs --------
while (1) {
	print "Watching logs from container: $container_name\n";

	open(my $fh, "-|", "docker logs -f $container_name 2>&1")
		or do {
			warn "Cannot run docker logs: $!\n";
			sleep 5;
			next;
		};

	while (my $line = <$fh>) {
		chomp $line;

		foreach my $pattern (@error_patterns) {
			if (!$alert_sent && $line =~ $pattern) {
				print "Detected error: $line\n";

				# Send email once
				send_email_once($line);

				# Stop container, power cycle USB, start container
				# toggle_modem_power_with_container_restart();
				last;
			}
		}
	}

	warn "docker logs stream ended — reconnecting in 5 sec...\n";
	sleep 5;
}
