#!/usr/bin/perl -w

use strict;
use Data::Dumper;
use DBI;
use Time::HiRes qw( usleep );

use Nabovarme::MQTT_RPC;
use Nabovarme::FirmwareSupport;
use Nabovarme::Utils;

use constant RPC_TIMEOUT => 0;	# 0 = never time out in queue, wait for meter reply

$SIG{HUP} = \&get_version_and_status;
$SIG{USR1} = \&get_wifi_scan_results_and_daily;

$SIG{INT} = \&sig_int_handler;

log_info("starting...");

my $dbh;
my $sth;
my $d;

my $nabovarme_mqtt = new Nabovarme::MQTT_RPC;
$nabovarme_mqtt->connect() || die $!;

# connect to db
if ($dbh = Nabovarme::Db->my_connect) {
	$dbh->{'mysql_auto_reconnect'} = 1;
	log_info("Connected to DB");
}
else {
	log_warn("Cant't connect to DB $!");
	die $!;
}

get_version_and_status();
while (1) {
	sleep 60;
}

# end of main

sub get_version_and_status {
	$sth = $dbh->prepare(qq[SELECT `type`, `serial`, `key`, `version` FROM meters WHERE `key` is not NULL AND `type` NOT LIKE 'aggregated' AND `enabled` = 1]);
	$sth->execute;

	log_info("send mqtt retain to all meters for version and status");
	while ($d = $sth->fetchrow_hashref) {
		log_info("send mqtt version, status and uptime commands to " . $d->{serial});

		# send version
		send_rpc($d, 'version');

		unless ($d->{type} =~ /^electricity$/i) {
			# send status
			send_rpc($d, 'status');
		}

		# send uptime
		send_rpc($d, 'uptime');

		# send ssid
		send_rpc($d, 'ssid');

		# send rssi
		send_rpc($d, 'rssi');

		# send wifi_status
		send_rpc($d, 'wifi_status');

		# send ap_status
		send_rpc($d, 'ap_status');

		# send reset_reason
		send_rpc($d, 'reset_reason');

		# send network_quality
		send_rpc($d, 'network_quality');
	}
}

sub get_wifi_scan_results_and_daily {
	$sth = $dbh->prepare(qq[SELECT `serial`, `key`, `version` FROM meters WHERE `key` is not NULL AND `type` NOT LIKE 'aggregated']);
	$sth->execute;

	log_info("send mqtt scan command to all meters");
	while ($d = $sth->fetchrow_hashref) {
		log_info("send mqtt scan commands to " . $d->{serial});

		send_rpc($d, 'scan');

		# send chip_id
		send_rpc($d, 'chip_id');

		# send flash_id
		send_rpc($d, 'flash_id');

		# send flash_size
		send_rpc($d, 'flash_size');
	}
}

sub send_rpc {
	my ($meter, $function) = @_;

	unless (firmware_supports($meter->{version}, $function)) {
		log_debug("Skipping unsupported RPC '$function' for meter $meter->{serial} (firmware version " .
			(defined $meter->{version} ? $meter->{version} : 'unknown') . ")");
		return;
	}

	$nabovarme_mqtt->call({
		serial   => $meter->{serial},
		function => $function,
		param    => '1',
		stateful => 0,
		callback => undef,
		timeout  => RPC_TIMEOUT
	});
}

sub sig_int_handler {
	log_die($!, {-no_script_name => 1});
}

1;
__END__
