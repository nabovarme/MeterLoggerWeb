#!/usr/bin/perl

use strict;
use warnings;

use Redis;
use DBI;
use Storable qw(thaw);
use Encode qw(decode FB_DEFAULT);

use Nabovarme::Db;
use Nabovarme::Crypto;
use Nabovarme::Utils;

$SIG{INT} = sub {
	log_info("Caught SIGINT, exiting.", {-no_script_name => 1});
	exit 0;
};

my $redis_host = $ENV{'REDIS_HOST'}
	or log_die("REDIS_HOST not set");
my $redis_port = $ENV{'REDIS_PORT'}
	or log_die("REDIS_PORT not set");

my $redis = Redis->new(
	server => "$redis_host:$redis_port",
	reconnect => 60,
);

my $dbh = Nabovarme::Db->my_connect
	or log_die("Can't connect to DB $!");
$dbh->{'mysql_auto_reconnect'} = 1;

my $crypto = Nabovarme::Crypto->new;
my %LOG_EVENTS = (
	'flash_error'       => 'flash_error',
	'cnx_csa_fn_called' => 'cnx_csa_fn_called',
	'vdd'               => 'vdd',
	'mem'               => 'free_heap'
);

log_info("Starting Event & Audit Worker (PID $$)...", {-no_script_name => 1});

sub decode_ssid {
	my ($raw) = @_;
	return undef unless defined $raw;

	my $ssid = decode('UTF-8', $raw, FB_DEFAULT);
	$ssid =~ s/[\x00-\x1F\x7F]//g;

	return $ssid;
}

while (1) {
	my ($q, $payload) = $redis->blpop('mqtt:queue:events', 86400);
	next unless $payload;

	unless ($dbh && $dbh->ping) {
		log_die("Database connection lost. Exiting for Docker restart.", {-no_script_name => 1});
	}

	my $data = thaw($payload);
	my ($topic, $message) = ($data->{topic}, $data->{message});

	my ($function, $meter_serial, $unix_time) = $topic =~ m!/([^/]+)/v\d+/([^/]+)(?:/(\d+))?!;

	next unless $meter_serial;

	my $cleartext = $crypto->decrypt_topic_message_for_serial(
		$topic,
		$message,
		$meter_serial,
	);

	unless (defined $cleartext) {
		log_debug("Decryption returned no cleartext for $topic", {-no_script_name => 1});
		next;
	}

	$cleartext =~ s/[\x00\s]+$//;

	# Handle Wi-Fi Site Survey Ingestion
	if ($function eq 'scan_result') {
		$cleartext =~ s/&$//;
		my %mq = $cleartext =~ /([^=]*)=(.*?)(?:&|$)/g;

		$mq{ssid} = substr($mq{ssid} || '', 0, 64);
		my $ssid_utf8 = decode_ssid($mq{ssid});
		$ssid_utf8 = substr($ssid_utf8, 0, 64) if defined $ssid_utf8 && length($ssid_utf8) > 64;

		my $sth = $dbh->prepare(
			qq[INSERT INTO `wifi_scan` (`serial`, `ssid_raw`, `ssid`, `bssid`, `rssi`, `channel`, `auth_mode`, `pairwise_cipher`, `group_cipher`, `phy_11b`, `phy_11g`, `phy_11n`, `wps`, `unix_time`) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, UNIX_TIMESTAMP())]
		);

		$sth->execute(
			$meter_serial, $mq{ssid}, $ssid_utf8, $mq{bssid}, $mq{rssi},
			$mq{channel}, $mq{auth_mode}, $mq{pairwise_cipher}, $mq{group_cipher},
			$mq{phy_11b}, $mq{phy_11g}, $mq{phy_11n}, $mq{wps},
		);

		if ($sth->err) {
			log_warn($sth->errstr, {-no_script_name => 1});
			$redis->rpush('mqtt:queue:events', $payload);
		}
		else {
			log_debug("Inserted wifi_scan result for serial $meter_serial: SSID='$mq{ssid}' RSSI=$mq{rssi}", {-no_script_name => 1});
		}

		next;
	}

	# Known System Events
	my $event_name = $LOG_EVENTS{$function} // $function;

	if ($event_name eq 'offline') {
		my ($last_updated) = $dbh->selectrow_array(
			qq[SELECT `last_updated` FROM `meters` WHERE `serial` = ?],
			undef,
			$meter_serial,
		);

		next if defined $last_updated && defined $unix_time && $unix_time < $last_updated;

		$dbh->do(
			qq[INSERT INTO `log` (`serial`, `function`, `param`, `unix_time`) VALUES (?, ?, ?, ?)],
			undef,
			$meter_serial, $event_name,
			$cleartext, $unix_time // time(),
		);

		log_debug("Logged event '$event_name' for serial $meter_serial", {-no_script_name => 1});
		next;
	}

	# Insert event entry into `log` only if param has changed
	my ($last_param) = $dbh->selectrow_array(
		qq[SELECT `param` FROM `log` WHERE `serial` = ? AND `function` = ? ORDER BY `unix_time` DESC LIMIT 1],
		undef,
		$meter_serial, $event_name,
	);

	next if defined $last_param && $last_param eq $cleartext;

	$dbh->do(
		qq[INSERT INTO `log` (`serial`, `function`, `param`, `unix_time`) VALUES (?, ?, ?, ?)],
		undef,
		$meter_serial, $event_name,
		$cleartext, $unix_time // time(),
	);

	log_debug("Logged event '$event_name' for serial $meter_serial", {-no_script_name => 1});
}
