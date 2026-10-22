#!/usr/bin/perl

use strict;
use warnings;

use Redis;
use DBI;
use Storable qw(thaw);

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

my %STATUS_FIELDS = (
	'version'         => 'sw_version',
	'status'          => 'valve_status',
	'uptime'          => 'uptime',
	'reset_reason'    => 'reset_reason',
	'ssid'            => 'ssid',
	'rssi'            => 'rssi',
	'wifi_status'     => 'wifi_status',
	'ap_status'       => 'ap_status',
	'set_ap_mesh_pwd' => 'mesh_pwd',
	'chip_id'         => 'chip_id',
	'flash_id'        => 'flash_id',
	'flash_size'      => 'flash_size',
);

log_info("Starting Device State Worker (PID $$)...", {-no_script_name => 1});

while (1) {
	my ($q, $payload) = $redis->blpop('mqtt:queue:meters', 86400);
	next unless $payload;

	unless ($dbh && $dbh->ping) {
		log_die("Database connection lost. Exiting for Docker restart.", {-no_script_name => 1});
	}

	my $data = thaw($payload);
	my ($topic, $message) = ($data->{topic}, $data->{message});

	my ($function, $meter_serial, $unix_time) =
		$topic =~ m!/([^/]+)/v\d+/([^/]+)(?:/(\d+))?!;

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

	# Handle direct open/close state updates
	if ($function eq 'open' || $function eq 'close') {
		$dbh->do(
			qq[UPDATE meters SET valve_status = ? WHERE serial = ?],
			undef,
			$function,
			$meter_serial,
		);
		log_debug("$topic\tUpdated valve_status to $function", {-no_script_name => 1});
	}
	# Update mapped state columns
	elsif (exists $STATUS_FIELDS{$function}) {
		$dbh->do(
			qq[UPDATE meters SET $STATUS_FIELDS{$function} = ? WHERE serial = ?],
			undef,
			$cleartext,
			$meter_serial,
		);
		log_debug("$topic\tUpdated $STATUS_FIELDS{$function} = $cleartext", {-no_script_name => 1});
	}
	# Handle complex network quality payloads
	elsif ($function eq 'network_quality') {
		$cleartext =~ s/&$//;
		my %mq = $cleartext =~ /([^=]*)=(.*?)(?:&|$)/g;

		$dbh->do(
			qq[UPDATE meters SET ping_response_time=?, ping_average_packet_loss=?, disconnect_count=? WHERE serial=?],
			undef,
			$mq{ping_response_time},
			$mq{ping_average_packet_loss},
			$mq{disconnect_count},
			$meter_serial,
		);
		log_debug("$topic\tUpdated network_quality", {-no_script_name => 1});
	}
}
