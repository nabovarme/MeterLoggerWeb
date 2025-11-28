#!/usr/bin/perl

use strict;
use warnings;
use Net::SMTP;
use Time::HiRes qw(time);

$| = 1;  # disable STDOUT buffering

my $container_name = "smsd";
my $usb_vendor = "0x12d1";
my $usb_product = "0x1001";

# Cooldown between resets (seconds)
my $reset_cooldown = 60;
my $last_reset_time = 0;

# Watch for registration errors AND SMS sending failures (partial match)
my @error_patterns = (
	qr/REGISTERED/i,
	qr/FAILED/i,
	qr/REJECTED/i,
	qr/CMS ERROR/i,
	qr/CME ERROR/i,
	qr/Message not sent/i,
	qr/Giving up/i,
	qr/Killed by signal/i,
	qr/Modem handler/i,
	qr/serial port/i,
	qr/No answer/i,
);

# ---- SMTP config ----
my $smtp_host = $ENV{SMTP_SERVER}   || 'smtp.example.com';
my $smtp_port = $ENV{SMTP_PORT}     || 587;   # STARTTLS port
my $smtp_user = $ENV{SMTP_USER}     || 'user@example.com';
my $smtp_pass = $ENV{SMTP_PASSWORD} || 'password';
my $to_email  = $ENV{TO_EMAIL}      || 'alert@example.com';

# Prevent multiple emails for the same error line
my $alert_sent = 0;

# ---- Send single email ----
sub send_email_once {
	my ($msg) = @_;
	return if $alert_sent;

	my $smtp = Net::SMTP->new(
		$smtp_host,
		Port            => $smtp_port,
		Timeout         => 20,
		Debug           => 0,
		SSL_verify_mode => 0,  # WARNING: disables TLS certificate verification
	) or do {
		warn "SMTP connect failed\n";
		return;
	};

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

# ---- Software reset of Huawei modem + Docker restart with cooldown ----
sub reset_modem_and_restart_container {
	my $now = time();
	if ($now - $last_reset_time < $reset_cooldown) {
		print "Cooldown active, skipping reset.\n";
		return;
	}

	print "Power-cycling Huawei modem via usb_modeswitch...\n";
	system("usb_modeswitch -v $usb_vendor -p $usb_product -R") == 0
		or warn "Failed to reset modem via usb_modeswitch\n";

	# wait for modem to reinitialize
	sleep 5;

	print "Restarting Docker container '$container_name'...\n";
	system("docker restart $container_name") == 0
		or warn "Failed to restart container $container_name\n";

	print "Modem reset and container restart completed.\n";

	$last_reset_time = $now;  # mark last reset
	$alert_sent = 0;		   # allow future alerts
}

# -------- Watch docker logs, only new logs --------
while (1) {
	my $since_time = `date -u +%Y-%m-%dT%H:%M:%S`;
	chomp $since_time;

	print "Watching logs from container: $container_name since $since_time\n";

	open(my $fh, "-|", "docker logs -f --since $since_time $container_name 2>&1")
		or do {
			warn "Cannot run docker logs: $!\n";
			sleep 5;
			next;
		};

	while (my $line = <$fh>) {
		chomp $line;
		$line =~ s/^\s+|\s+$//g;  # trim whitespace

		foreach my $pattern (@error_patterns) {
			if ($line =~ $pattern) {
				print "Detected error: $line\n";

				# Send email once per session
				send_email_once($line);

				# Reset modem and restart container with cooldown
				reset_modem_and_restart_container();

				last;
			}
		}
	}

	warn "docker logs stream ended — reconnecting in 5 sec...\n";
	sleep 5;
}
