#!/usr/bin/perl -w

use strict;
use warnings;
use Redis;
use DBI;
use Storable qw(thaw);

use Nabovarme::Db;
use Nabovarme::Crypto;
use Nabovarme::Utils;

# Set signal handler for clean manual worker termination
$SIG{INT} = sub { log_info("Caught SIGINT, exiting.", {-no_script_name => 1}); exit 0; };

my $redis_host = $ENV{'REDIS_HOST'} or log_die("ERROR: REDIS_HOST not set");
my $redis_port = $ENV{'REDIS_PORT'} or log_die("ERROR: REDIS_PORT not set");
my $redis = Redis->new(server => "$redis_host:$redis_port", reconnect => 60);

my $dbh = Nabovarme::Db->my_connect or log_die("Cant't connect to DB $!");
$dbh->{'mysql_auto_reconnect'} = 1;

my $crypto = new Nabovarme::Crypto;

log_info("Starting Command ACK Worker...", {-no_script_name => 1});

while (1) {
	my ($q, $payload) = $redis->blpop('mqtt:queue:cmd_ack', 86400);
	next unless $payload;

	unless ($dbh && $dbh->ping) {
		log_die("Database connection lost. Exiting for Docker to restart.", {-no_script_name => 1});
	}

	my $data = thaw($payload);
	my ($topic, $message) = ($data->{topic}, $data->{message});

	my ($function, $meter_serial, $unix_time) = $topic =~ m!/([^/]+)/v\d+/([^/]+)/(\d+)!;
	next unless $meter_serial;

	my $cleartext = $crypto->decrypt_topic_message_for_serial($topic, $message, $meter_serial);
	next unless defined $cleartext;
	$cleartext =~ s/[\x00\s]+$//;

	# --- Special Case: open_until ---
	if ($function =~ /^open_until/i) {
		my $tolerance = 1;
		$dbh->do(qq[DELETE FROM command_queue WHERE serial = ? AND function = ? AND param <= ?], undef, $meter_serial, $function, $cleartext + $tolerance);
		log_info("Cleared open_until <= $cleartext for $meter_serial", {-no_script_name => 1});
		next;
	}

	# --- Special Case: status ---
	if ($function =~ /^status$/i) {
		$dbh->do(qq[DELETE FROM command_queue WHERE serial = ? AND function = ?], undef, $meter_serial, $function);
		log_info("Deleted status command for $meter_serial", {-no_script_name => 1});
		next;
	}

	# --- General ACKs & Callback Resolution ---
	my $lookup_function = $function;
	$lookup_function = 'test_ssid_pwd' if $function eq 'test_ssid_pwd_result';
	$lookup_function = 'read_stack_trace' if $function eq 'stack_trace_result';
	$lookup_function = 'scan' if $function eq 'scan_result';

	my $state_clause = ($function =~ /^ota_up(?:date|grade)$/i || $function =~ /^test_ssid_pwd_result$/i)
						? "state IN ('sent', 'received')" : "state = 'sent'";

	my $sth = $dbh->prepare(qq[SELECT id, has_callback FROM command_queue WHERE serial = ? AND function = ? AND $state_clause]);
	$sth->execute($meter_serial, $lookup_function);

	while (my $d = $sth->fetchrow_hashref) {
		if ($d->{has_callback}) {
			# (Scan result specifically passes an empty string for the param back to the DB to match legacy behavior)
			my $insert_param = ($function eq 'scan_result') ? '' : $cleartext;
			$dbh->do(qq[INSERT INTO command_responses (command_id, param, unix_time) VALUES (?, ?, UNIX_TIMESTAMP())], undef, $d->{id}, $insert_param);
			$dbh->do(qq[UPDATE command_queue SET state = 'received', unix_time = UNIX_TIMESTAMP() WHERE id = ?], undef, $d->{id});
			log_info("Marked serial $meter_serial, command $lookup_function for callback resolution", {-no_script_name => 1});
		} else {
			$dbh->do(qq[DELETE FROM command_queue WHERE id = ?], undef, $d->{id});
			log_info("Deleted serial $meter_serial, command $lookup_function", {-no_script_name => 1});
		}
	}
}
