#!/usr/bin/perl

use strict;
use warnings;
use Net::SMTP;
use Time::HiRes qw(time);

$| = 1;  # disable STDOUT buffering

# Watch only postfix container
my $container = "postfix";

# ---- Postfix error patterns ----
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

# Prevent multiple emails for the same error line in a session
my %sent_alerts;

# ---- Send email ----
sub send_email {
	my ($msg) = @_;
	return if $sent_alerts{$msg};

	my $smtp = Net::SMTP->new(
		$smtp_host,
		Port            => $smtp_port,
		Timeout         => 20,
		Debug           => 0,
		SSL_verify_mode => 0,
	) or do { warn "SMTP connect failed\n"; return; };

	eval { $smtp->starttls(); };

	unless ($smtp->auth($smtp_user, $smtp_pass)) {
		warn "SMTP auth failed\n";
		return;
	}

	$smtp->mail($from_email);
	$smtp->to(@to_list);

	$smtp->data();
	$smtp->datasend("To: " . join(",", @to_list) . "\n");
	$smtp->datasend("From: $from_email\n");
	$smtp->datasend("Subject: Postfix alert detected\n");
	$smtp->datasend("\n$msg\n");
	$smtp->dataend();
	$smtp->quit();

	print "Email sent: $msg\n";
	$sent_alerts{$msg} = 1;
}

# -------- Watch postfix docker logs --------
while (1) {
	my $since_time = `date -u +%Y-%m-%dT%H:%M:%S`;
	chomp $since_time;
	print "Watching logs from container: $container since $since_time\n";

	open(my $fh, "-|", "docker logs -f --since $since_time $container 2>&1")
		or do { warn "Cannot run docker logs: $!\n"; sleep 5; next; };

	while (my $line = <$fh>) {
		chomp $line;
		$line =~ s/^\s+|\s+$//g;  # trim whitespace

		foreach my $pattern (@error_patterns) {
			if ($line =~ $pattern) {
				print "Detected error in $container: $line\n";
				send_email("$container: $line");
				last;
			}
		}
	}

	warn "docker logs stream ended — reconnecting in 5 sec...\n";
	sleep 5;
}
