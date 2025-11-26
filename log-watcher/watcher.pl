#!/usr/bin/perl

use strict;
use warnings;
use Net::SMTP::SSL;

my $container_name = "smsd";
my $search_text	= "MODEM IS NOT REGISTERED";

# ---- SMTP config ----
my $smtp_host = $ENV{SMTP_SERVER}	|| 'smtp.example.com';
my $smtp_port = $ENV{SMTP_PORT}		|| 465;
my $smtp_user = $ENV{SMTP_USER}		|| 'user@example.com';
my $smtp_pass = $ENV{SMTP_PASSWORD}	|| 'password';
my $to_email  = $ENV{TO_EMAIL}		|| 'alert@example.com';

# Prevent multiple emails
my $email_sent = 0;

sub send_email_once {
	my ($msg) = @_;

	return if $email_sent;   # already sent once

	my $smtp = Net::SMTP::SSL->new(
		$smtp_host,
		Port	=> $smtp_port,
		Timeout => 20,
	) or do {
		warn "SMTP connect failed\n";
		return;
	};

	unless ($smtp->auth($smtp_user, $smtp_pass)) {
		warn "SMTP auth failed\n";
		return;
	}

	$smtp->mail($smtp_user);
	$smtp->to($to_email);

	$smtp->data();
	$smtp->datasend("To: $to_email\n");
	$smtp->datasend("From: $smtp_user\n");
	$smtp->datasend("Subject: Modem alert detected\n");
	$smtp->datasend("\n$msg\n");
	$smtp->dataend();
	$smtp->quit();

	print "Email sent: $msg\n";
	$email_sent = 1;  # no more emails
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

		if (!$email_sent && $line =~ /\Q$search_text\E/) {
			print "Detected modem error: $line\n";
			send_email_once($line);
		}
	}

	warn "docker logs stream ended — reconnecting in 5 sec...\n";
	sleep 5;
}
