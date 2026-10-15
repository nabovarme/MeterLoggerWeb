#!/usr/bin/perl -w

use strict;
use warnings;
use Redis;
use DBI;
use Storable qw(thaw);
use Time::HiRes qw(gettimeofday);

use Nabovarme::Db;
use Nabovarme::Crypto;
use Nabovarme::Utils;

sub get_timestamp_ms {
	my ($seconds, $microseconds) = gettimeofday();
	my ($sec, $min, $hour, $mday, $mon, $year) = localtime($seconds);

	return sprintf(
		"%04d-%02d-%02d %02d:%02d:%02d.%03d",
		$year + 1900,
		$mon + 1,
		$mday,
		$hour,
		$min,
		$sec,
		int($microseconds / 1000),
	);
}

$SIG{INT} = sub {
	log_info("Caught SIGINT, exiting.", {-no_script_name => 1});
	exit 0;
};

my $redis_host = $ENV{'REDIS_HOST'}
	or log_die("ERROR: REDIS_HOST not set");
my $redis_port = $ENV{'REDIS_PORT'}
	or log_die("ERROR: REDIS_PORT not set");

my $redis = Redis->new(
	server => "$redis_host:$redis_port",
	reconnect => 60,
);

my $dbh = Nabovarme::Db->my_connect
	or log_die("Cant't connect to DB $!");
$dbh->{'mysql_auto_reconnect'} = 1;

my $crypto = new Nabovarme::Crypto;

log_info("Starting Command ACK Worker (PID $$)...", {-no_script_name => 1});

while (1) {
	my ($q, $payload) = $redis->blpop('mqtt:queue:cmd_ack', 86400);
	next unless $payload;

	my $pop_time = get_timestamp_ms();

	unless ($dbh && $dbh->ping) {
		log_die(
			"Database connection lost. Exiting for Docker to restart.",
			{-no_script_name => 1},
		);
	}

	my $data = thaw($payload);
	my ($topic, $message) = ($data->{topic}, $data->{message});

	log_info(
		"DEBUG [PID $$] [$pop_time] POPPED -> $topic",
		{-no_script_name => 1},
	);

	my ($function, $meter_serial, $unix_time) =
		$topic =~ m!^/([^/]+)/v\d+/([^/]+)/(\d+)!;

	unless ($function && $meter_serial) {
		log_warn(
			"DEBUG [PID $$] Failed to parse function/serial from topic: $topic",
			{-no_script_name => 1},
		);
		next;
	}

	next if $function =~ /^config$/i;

	# Pre-check if commands exist
	my $sth = $dbh->prepare(qq[
		SELECT serial
		FROM command_queue
		WHERE serial = ?
		LIMIT 1
	]);
	$sth->execute($meter_serial);

	unless ($sth->rows) {
		log_info(
			"DEBUG [PID $$] No pending commands in DB for serial $meter_serial. Dropping ACK.",
			{-no_script_name => 1},
		);
		next;
	}

	my $cleartext = $crypto->decrypt_topic_message_for_serial(
		$topic,
		$message,
		$meter_serial,
	);

	if (defined $cleartext) {
		$cleartext =~ s/[\x00\s]+$//;

		log_info(
			"DEBUG [PID $$] Decrypted payload for $meter_serial:$function -> '$cleartext'",
			{-no_script_name => 1},
		);

		my $lookup_function = $function;
		$lookup_function = 'test_ssid_pwd'
			if $function =~ /^test_ssid_pwd_result$/i;
		$lookup_function = 'read_stack_trace'
			if $function =~ /^stack_trace_result$/i;
		$lookup_function = 'scan'
			if $function =~ /^scan_result$/i;

		if ($function =~ /^open_until/i) {
			my $tolerance = 1;

			my $rows = $dbh->do(
				qq[
					DELETE FROM command_queue
					WHERE serial = ?
					AND function = ?
					AND param <= ?
				],
				undef,
				$meter_serial,
				$function,
				$cleartext + $tolerance,
			);

			log_info(
				"DEBUG [PID $$] Deleted $rows open_until commands <= $cleartext for $meter_serial",
				{-no_script_name => 1},
			);
			next;
		}

		if ($function =~ /^status$/i) {
			my $rows = $dbh->do(
				qq[
					DELETE FROM command_queue
					WHERE serial = ?
					AND function = ?
				],
				undef,
				$meter_serial,
				$function,
			);

			log_info(
				"DEBUG [PID $$] Deleted $rows status commands for $meter_serial",
				{-no_script_name => 1},
			);
			next;
		}

		$sth = $dbh->prepare(qq[
			SELECT id, has_callback
			FROM command_queue
			WHERE serial = ?
			AND function = ?
			AND state IN ('sent', 'received')
		]);

		$sth->execute($meter_serial, $lookup_function) or do {
			log_warn(
				"DEBUG [PID $$] DB Error: " . $DBI::errstr,
				{-no_script_name => 1},
			);
			$redis->rpush('mqtt:queue:cmd_ack', $payload);
			next;
		};

		if ($sth->rows == 0) {
			log_info(
				"DEBUG [PID $$] No matching command_queue entry for $meter_serial -> $lookup_function",
				{-no_script_name => 1},
			);
		}

		while (my $row = $sth->fetchrow_hashref) {
			if ($row->{has_callback}) {
				$dbh->do(
					qq[
						INSERT INTO command_responses
							(command_id, param, unix_time)
						VALUES (?, ?, UNIX_TIMESTAMP())
					],
					undef,
					$row->{id},
					$cleartext,
				);

				$dbh->do(
					qq[
						UPDATE command_queue
						SET state = 'received', unix_time = UNIX_TIMESTAMP()
						WHERE id = ?
					],
					undef,
					$row->{id},
				);

				log_info(
					"DEBUG [PID $$] Marked $lookup_function (ID: $row->{id}) for callback resolution",
					{-no_script_name => 1},
				);
			}
			else {
				$dbh->do(
					qq[DELETE FROM command_queue WHERE id = ?],
					undef,
					$row->{id},
				);

				log_info(
					"DEBUG [PID $$] Deleted fire-and-forget $lookup_function (ID: $row->{id})",
					{-no_script_name => 1},
				);
			}
		}
	}
	else {
		log_warn(
			"DEBUG [PID $$] Serial $meter_serial HMAC error on topic $topic",
			{-no_script_name => 1},
		);
	}
}
