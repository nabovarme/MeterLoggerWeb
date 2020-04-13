#!/usr/bin/perl -w

use strict;
use Data::Dumper;
use Sys::Syslog;
use Net::MQTT::Simple;
use DBI;
use Crypt::Mode::CBC;
use Digest::SHA qw( sha256 hmac_sha256 );
use Time::HiRes qw( gettimeofday tv_interval );
use Config;

use lib qw( /etc/apache2/perl );
use lib qw( /opt/local/apache2/perl/ );
use Nabovarme::Db;
use Nabovarme::Crypto;

$SIG{INT} = \&sig_int_handler;

openlog($0, "ndelay,pid", "local0");
syslog('info', "starting...");

my $protocol_version;
my $unix_time;
my $meter_serial;
my $sw_version;
my $valve_status;
my $uptime;
my $ssid;
my $rssi;
my $wifi_status;
my $ap_status;
my $reset_reason;

my $mqtt;
if ($Config{osname} =~ /darwin/) {
	$mqtt = Net::MQTT::Simple->new(q[10.8.0.84]);
}
else {
	$mqtt = Net::MQTT::Simple->new(q[127.0.0.1]);
}
my $mqtt_data = undef;
#my $mqtt_count = 0;

sub sig_int_handler {
	$mqtt->disconnect();
	die $!;
}
# connect to db
my $dbh;
if ($dbh = Nabovarme::Db->my_connect) {
	$dbh->{'mysql_auto_reconnect'} = 1;
	syslog('info', "connected to db");
}
else {
	syslog('info', "cant't connect to db $!");
	die $!;
}

my $crypto = new Nabovarme::Crypto;

# start mqtt run loop
$mqtt->run(	q[/version/v2/#] => \&v2_mqtt_version_handler,
	q[/status/v2/#] => \&v2_mqtt_status_handler,
	q[/uptime/v2/#] => \&v2_mqtt_uptime_handler,
	q[/ssid/v2/#] => \&v2_mqtt_ssid_handler,
	q[/rssi/v2/#] => \&v2_mqtt_rssi_handler,
	q[/wifi_status/v2/#] => \&v2_mqtt_wifi_status_handler,
	q[/ap_status/v2/#] => \&v2_mqtt_ap_status_handler,
	q[/reset_reason/v2/#] => \&v2_mqtt_reset_reason_handler,
	q[/scan_result/v2/#] => \&v2_mqtt_scan_result_handler,
#	q[/crypto/v2/#] => \&v2_mqtt_crypto_test_handler
);

# end of main


sub v2_mqtt_version_handler {
	my ($topic, $message) = @_;
	my $m;

	unless ($topic =~ m!/version/v\d+/([^/]+)/(\d+)!) {
	        return;
	}
	$meter_serial = $1;
	$unix_time = $2;

	$sw_version = $crypto->decrypt_topic_message_for_serial($topic, $message, $meter_serial);
	if ($sw_version) {	
		# remove trailing nulls
		$sw_version =~ s/[\x00\s]+$//;
		$sw_version .= '';

		my $quoted_sw_version = $dbh->quote($sw_version);
		my $quoted_meter_serial = $dbh->quote($meter_serial);
		my $quoted_unix_time = $dbh->quote($unix_time);
		$dbh->do(qq[UPDATE meters SET \
						sw_version = $quoted_sw_version, \
						last_updated = $quoted_unix_time \
						WHERE serial = $quoted_meter_serial AND $quoted_unix_time > last_updated]) or warn $!;
						syslog('info', $topic . "\t" . $sw_version);
						warn $topic . "\t" . $sw_version;
	}
	else {
		# hmac sha256 not ok
		syslog('info', $topic . "hmac error");
		syslog('info', $topic . "\t" . unpack('H*', $message));
		warn $topic . "\t" . unpack('H*', $message);
	}
}

sub v2_mqtt_status_handler {
	my ($topic, $message) = @_;
	my $m;
	
	unless ($topic =~ m!/status/v\d+/([^/]+)/(\d+)!) {
		return;
	}
	$meter_serial = $1;
	$unix_time = $2;

	$valve_status = $crypto->decrypt_topic_message_for_serial($topic, $message, $meter_serial);
	if ($valve_status) {	
		# remove trailing nulls
		$valve_status =~ s/[\x00\s]+$//;
		$valve_status .= '';

		my $quoted_valve_status = $dbh->quote($valve_status);
		my $quoted_meter_serial = $dbh->quote($meter_serial);
		my $quoted_unix_time = $dbh->quote($unix_time);
		$dbh->do(qq[UPDATE meters SET \
						valve_status = $quoted_valve_status, \
						last_updated = $quoted_unix_time \
						WHERE serial = $quoted_meter_serial AND $quoted_unix_time > last_updated]) or warn $!;
		warn $topic . "\t" . $valve_status;
		syslog('info', 'valve_status changed' . " " . $meter_serial . " " . $valve_status);
		
	}
	else {
		# hmac sha256 not ok
		warn Dumper("serial $meter_serial checksum error");
	}
}

sub v2_mqtt_uptime_handler {
	my ($topic, $message) = @_;
	my $m;
	
	unless ($topic =~ m!/uptime/v\d+/([^/]+)/(\d+)!) {
		return;
	}
	$meter_serial = $1;
	$unix_time = $2;
	
	$uptime = $crypto->decrypt_topic_message_for_serial($topic, $message, $meter_serial);
	if ($uptime) {	
		# remove trailing nulls
		$uptime =~ s/[\x00\s]+$//;
		$uptime .= '';

		my $quoted_uptime = $dbh->quote($uptime);
		my $quoted_meter_serial = $dbh->quote($meter_serial);
		my $quoted_unix_time = $dbh->quote($unix_time);
		$dbh->do(qq[UPDATE meters SET \
						uptime = $quoted_uptime, \
						last_updated = $quoted_unix_time \
						WHERE serial = $quoted_meter_serial AND $quoted_unix_time > last_updated]) or warn $!;
		warn $topic . "\t" . $uptime;
	}
	else {
		# hmac sha256 not ok
		warn Dumper("serial $meter_serial checksum error");
	}
}

sub v2_mqtt_ssid_handler {
	my ($topic, $message) = @_;
	my $m;
	
	unless ($topic =~ m!/ssid/v\d+/([^/]+)/(\d+)!) {
		return;
	}
	$meter_serial = $1;
	$unix_time = $2;
	
	$ssid = $crypto->decrypt_topic_message_for_serial($topic, $message, $meter_serial);
	if ($ssid) {	
		# remove trailing nulls
		$ssid =~ s/[\x00\s]+$//;
		$ssid .= '';
       
		my $quoted_ssid = $dbh->quote($ssid);
		my $quoted_meter_serial = $dbh->quote($meter_serial);
		my $quoted_unix_time = $dbh->quote($unix_time);
		$dbh->do(qq[UPDATE meters SET \
						ssid = $quoted_ssid, \
						last_updated = $quoted_unix_time \
						WHERE serial = $quoted_meter_serial AND $quoted_unix_time > last_updated]) or warn $!;
		warn $topic . "\t" . $ssid;
	}
	else {
		# hmac sha256 not ok
		warn Dumper("serial $meter_serial checksum error");
	}
}

sub v2_mqtt_rssi_handler {
	my ($topic, $message) = @_;
	my $m;
	
	unless ($topic =~ m!/rssi/v\d+/([^/]+)/(\d+)!) {
		return;
	}
	$meter_serial = $1;
	$unix_time = $2;
	
	$rssi = $crypto->decrypt_topic_message_for_serial($topic, $message, $meter_serial);
	if ($rssi) {	
		# remove trailing nulls
		$rssi =~ s/[\x00\s]+$//;
		$rssi .= '';

		my $quoted_rssi = $dbh->quote($rssi);
		my $quoted_meter_serial = $dbh->quote($meter_serial);
		my $quoted_unix_time = $dbh->quote($unix_time);
		$dbh->do(qq[UPDATE meters SET \
						rssi = $quoted_rssi, \
						last_updated = $quoted_unix_time \
						WHERE serial = $quoted_meter_serial AND $quoted_unix_time > last_updated]) or warn $!;
		warn $topic . "\t" . $rssi;
	}
	else {
		# hmac sha256 not ok
		warn Dumper("serial $meter_serial checksum error");
	}
}

sub v2_mqtt_wifi_status_handler {
	my ($topic, $message) = @_;
	my $m;
	
	unless ($topic =~ m!/wifi_status/v\d+/([^/]+)/(\d+)!) {
		return;
	}
	$meter_serial = $1;
	$unix_time = $2;
	
	$wifi_status = $crypto->decrypt_topic_message_for_serial($topic, $message, $meter_serial);
	if ($wifi_status) {	
		# remove trailing nulls
		$wifi_status =~ s/[\x00\s]+$//;
		$wifi_status .= '';

		my $quoted_wifi_status = $dbh->quote($wifi_status);
		my $quoted_meter_serial = $dbh->quote($meter_serial);
		my $quoted_unix_time = $dbh->quote($unix_time);
		$dbh->do(qq[UPDATE meters SET \
						wifi_status = $quoted_wifi_status, \
						last_updated = $quoted_unix_time \
						WHERE serial = $quoted_meter_serial AND $quoted_unix_time > last_updated]) or warn $!;
		warn $topic . "\t" . $wifi_status;
	}
	else {
		# hmac sha256 not ok
		warn Dumper("serial $meter_serial checksum error");
	}
}

sub v2_mqtt_ap_status_handler {
	my ($topic, $message) = @_;
	my $m;
	
	unless ($topic =~ m!/ap_status/v\d+/([^/]+)/(\d+)!) {
		return;
	}
	$meter_serial = $1;
	$unix_time = $2;
	
	$ap_status = $crypto->decrypt_topic_message_for_serial($topic, $message, $meter_serial);
	if ($ap_status) {	
		# remove trailing nulls
		$ap_status =~ s/[\x00\s]+$//;
		$ap_status .= '';

		my $quoted_ap_status = $dbh->quote($ap_status);
		my $quoted_meter_serial = $dbh->quote($meter_serial);
		my $quoted_unix_time = $dbh->quote($unix_time);
		$dbh->do(qq[UPDATE meters SET \
						ap_status = $quoted_ap_status, \
						last_updated = $quoted_unix_time \
						WHERE serial = $quoted_meter_serial AND $quoted_unix_time > last_updated]) or warn $!;
		warn $topic . "\t" . $ap_status;
	}
	else {
		# hmac sha256 not ok
		warn Dumper("serial $meter_serial checksum error");
	}
}

sub v2_mqtt_reset_reason_handler {
	my ($topic, $message) = @_;
	my $m;
	
	unless ($topic =~ m!/reset_reason/v\d+/([^/]+)/(\d+)!) {
		return;
	}
	$meter_serial = $1;
	$unix_time = $2;
	
	$reset_reason = $crypto->decrypt_topic_message_for_serial($topic, $message, $meter_serial);
	if ($reset_reason) {	
		# remove trailing nulls
		$reset_reason =~ s/[\x00\s]+$//;
		$reset_reason .= '';

		# handle long reset reason string
		$reset_reason =~ s/&/ /g;
		
		my $quoted_reset_reason = $dbh->quote($reset_reason);
		my $quoted_meter_serial = $dbh->quote($meter_serial);
		my $quoted_unix_time = $dbh->quote($unix_time);
		$dbh->do(qq[UPDATE meters SET \
						reset_reason = $quoted_reset_reason, \
						last_updated = $quoted_unix_time \
						WHERE serial = $quoted_meter_serial AND $quoted_unix_time > last_updated]) or warn $!;
		warn $topic . "\t" . $reset_reason;
	}
	else {
		# hmac sha256 not ok
		warn Dumper("serial $meter_serial checksum error");
	}
}

sub v2_mqtt_scan_result_handler {
	my ($topic, $message) = @_;
	my $m;

	unless ($topic =~ m!/scan_result/v\d+/([^/]+)/(\d+)!) {
		return;
	}
	
	$meter_serial = $1;
	$unix_time = $2;

	$message = $crypto->decrypt_topic_message_for_serial($topic, $message, $meter_serial);
	if ($message) {	
		# parse message
		$message =~ s/&$//;
	
		my ($key, $value, $unit);
		my @key_value_list = split(/&/, $message);
		my $key_value; 
		foreach $key_value (@key_value_list) {
			if (($key, $value) = $key_value =~ /([^=]*)=(.*)/) {
				$mqtt_data->{$key} = $value;
			}
		}		
		# save to db
		my $sth = $dbh->prepare(qq[INSERT INTO `wifi_scan` (
			`serial`,
			`ssid`,
			`bssid`,
			`rssi`,
			`channel`,
			`unix_time`
			) VALUES (] . 
			$dbh->quote($meter_serial) . ',' . 
			$dbh->quote($mqtt_data->{ssid}) . ',' . 
			$dbh->quote($mqtt_data->{bssid}) . ',' . 
			$dbh->quote($mqtt_data->{rssi}) . ',' . 
			$dbh->quote($mqtt_data->{channel}) . ',' . 
			'UNIX_TIMESTAMP()' . qq[)]);
		$sth->execute || syslog('info', "can't log to db");
		$sth->finish;
	
		syslog('info', $topic . " " . $message);
		warn $topic . "\t" . $message;
	}
	else {
		# hmac sha256 not ok

	}
	$mqtt_data = undef;
}

#sub v2_mqtt_crypto_test_handler {
#	my ($topic, $message) = @_;
#	my $m;
#
#	unless ($topic =~ m!/crypto/v\d+/([^/]+)/(\d+)!) {
#	        return;
#	}
#	$meter_serial = $1;
#	$unix_time = $2;
#
#	$message = $crypto->decrypt_topic_message_for_serial($topic, $message, $meter_serial);
#	if ($message) {	
#		warn Dumper({	"message" => unpack('H*', $message),
#						"aes key" => unpack('H*', $aes_key),
#						"hmac sha256 key" => unpack('H*', $hmac_sha256_key),
#						"iv" => unpack('H*', $iv),
#						"ciphertext" => unpack('H*', $ciphertext),
#						"mac" => unpack('H*', $mac),
#						"message" => $message,
#						"cleartext" => unpack('H*', $message)
#					});
#	}
#	else {
#		# hmac sha256 not ok
#		warn Dumper("serial $meter_serial checksum error");
#	}
#}

__END__
