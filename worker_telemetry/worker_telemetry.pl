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
		$year + 1900, $mon + 1, $mday, $hour, $min, $sec,
		int($microseconds / 1000)
	);
}

# Set signal handler for clean manual worker termination
$SIG{INT} = sub {
	log_info("Caught SIGINT, exiting.", {-no_script_name => 1});
	exit 0;
};

my $redis_host = $ENV{'REDIS_HOST'} or log_die("ERROR: REDIS_HOST not set");
my $redis_port = $ENV{'REDIS_PORT'} or log_die("ERROR: REDIS_PORT not set");
my $redis = Redis->new(server => "$redis_host:$redis_port", reconnect => 60);

my $dbh = Nabovarme::Db->my_connect or log_die("Cant't connect to DB $!");
$dbh->{'mysql_auto_reconnect'} = 1;

my $crypto = new Nabovarme::Crypto;

log_info("Starting Telemetry Worker (PID $$)...", {-no_script_name => 1});

while (1) {
	my ($q, $payload) = $redis->blpop('mqtt:queue:telemetry', 86400);
	next unless $payload;

	my $pop_time = get_timestamp_ms();

	unless ($dbh && $dbh->ping) {
		log_die("Database connection lost. Exiting for Docker to restart.", {-no_script_name => 1});
	}

	my $data = thaw($payload);
	my ($topic, $message) = ($data->{topic}, $data->{message});

	log_info(
		"DEBUG [PID $$] [$pop_time] POPPED queue item -> Topic:$topic | Msg len: " . length($message),
		{-no_script_name => 1}
	);

	my ($meter_serial, $unix_time) = $topic =~ m!/sample/v\d+/([^/]+)/(\d+)!;

	unless ($meter_serial) {
		log_warn(
			"DEBUG [PID $$] Could not parse serial/time from topic:$topic",
			{-no_script_name => 1}
		);
		next;
	}

	my $sample = $crypto->decrypt_topic_message_for_serial($topic, $message, $meter_serial);

	if (defined $sample) {
		$sample =~ s/&$//;

		my %mq;

		foreach my $kv (split(/&/, $sample)) {
			if (my ($key, $val, $unit) = $kv =~ /([^=]*)=(\S+)(?:\s+(.*))?/) {
				if ($key =~ /^e1$/i && defined $unit) {
					$val *= 1000 if $unit =~ /^MWh$/i;
					$val *= 277.77777777778 if $unit =~ /^Gj$/i;
				}

				$mq{$key} = $val;
			}
		}

		log_info(
			"DEBUG [PID $$] Attempting DB INSERT -> Serial:$meter_serial | UnixTime: $unix_time | FlowTemp: " .
			($mq{t1} // 'NULL'),
			{-no_script_name => 1}
		);

		my $sth = $dbh->prepare(
			qq[INSERT INTO `samples` (`serial`,`heap`,`flow_temp`,`return_flow_temp`,`temp_diff`,`t3`,`flow`,`effect`,`hours`,`volume`,`energy`,`unix_time`) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)]
		);

		$sth->execute(
			$meter_serial, $mq{heap}, $mq{t1}, $mq{t2}, $mq{tdif}, $mq{t3},
			$mq{flow1}, $mq{effect1}, $mq{hr}, $mq{v1}, $mq{e1}, $unix_time
		);

		if ($sth->err) {
			my $err_str = $sth->errstr;

			log_warn(
				"DEBUG [PID $$] DB INSERT ERROR:$err_str -> Re-queuing payload to Redis",
				{-no_script_name => 1}
			);

			# Rollback to queue
			$redis->rpush('mqtt:queue:telemetry', $payload);
		}
		else {
			my $rows = $sth->rows;

			log_info(
				"DEBUG [PID $$] DB INSERT SUCCESS (Rows affected:$rows) -> Serial: $meter_serial | UnixTime:$unix_time",
				{-no_script_name => 1}
			);

			$dbh->do(
				qq[UPDATE meters SET last_updated = ? WHERE serial = ? AND ? > last_updated],
				undef,
				$unix_time, $meter_serial, $unix_time
			);

			log_info("$topic$sample", {-no_script_name => 1});
		}
	}
	else {
		log_warn("DEBUG [PID $$]$topic hmac error", {-no_script_name => 1});
	}
}
