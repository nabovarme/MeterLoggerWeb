#!/usr/bin/perl -w

use strict;
use Data::Dumper;
use Sys::Syslog;
use Redis;
use DBI;
use Crypt::Mode::CBC;
use Digest::SHA qw( sha256 hmac_sha256 );
#use Time::HiRes qw( gettimeofday tv_interval );
use Config;

use lib qw( /etc/apache2/perl );
use lib qw( /opt/local/apache2/perl/ );

use Nabovarme::Db;
use Nabovarme::Crypto;

use constant CONFIG_FILE => qw (/etc/Nabovarme.conf );

$SIG{INT} = \&sig_int_handler;

my $config = new Config::Simple(CONFIG_FILE) || die $!;

openlog($0, "ndelay,pid", "local0");
syslog('info', "starting...");

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
my $flash_id;
my $flash_size;
my $disconnect_count;

my $redis_host = $config->param('redis_host') || '127.0.0.1';
my $redis_port = $config->param('redis_port') || '6379';
my $redis = Redis->new(
	server => "$redis_host:$redis_port",
);

my $queue_name	= 'mqtt';
my $timeout		= 86400;

my $mqtt_data = undef;

sub sig_int_handler {
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
while (1) {
	my ($queue, $job_id) = $redis->blpop(join(':', $queue_name, 'queue'), $timeout);
	if ($job_id) {
	
		my %data = $redis->hgetall($job_id);
	
		if ($data{topic} =~ /sample\/v2\//) {
			v2_mqtt_sample_handler($data{topic}, $data{message});
		}
		elsif ($data{topic} =~ /version\/v2/) {
			v2_mqtt_version_handler($data{topic}, $data{message});
		}
		elsif ($data{topic} =~ /status\/v2/) {
			v2_mqtt_status_handler($data{topic}, $data{message});
		}
		elsif ($data{topic} =~ /uptime\/v2/) {
			v2_mqtt_uptime_handler($data{topic}, $data{message});
		}
		elsif ($data{topic} =~ /ssid\/v2/) {
			v2_mqtt_ssid_handler($data{topic}, $data{message});
		}
		elsif ($data{topic} =~ /rssi\/v2/) {
			v2_mqtt_rssi_handler($data{topic}, $data{message});
		}
		elsif ($data{topic} =~ /wifi_status\/v2/) {
			v2_mqtt_wifi_status_handler($data{topic}, $data{message});
		}
		elsif ($data{topic} =~ /ap_status\/v2/) {
			v2_mqtt_wifi_status_handler($data{topic}, $data{message});
		}
		elsif ($data{topic} =~ /reset_reason\/v2/) {
			v2_mqtt_reset_reason_handler($data{topic}, $data{message});
		}
		elsif ($data{topic} =~ /scan_result\/v2/) {
			v2_mqtt_scan_result_handler($data{topic}, $data{message});
		}
		elsif ($data{topic} =~ /offline\/v1\//) {
			mqtt_offline_handler($data{topic}, $data{message});
		}
		elsif ($data{topic} =~ /flash_id\/v2/) {
			mqtt_flash_id_handler($data{topic}, $data{message});
		}
		elsif ($data{topic} =~ /flash_size\/v2/) {
			mqtt_flash_size_handler($data{topic}, $data{message});
		}
		elsif ($data{topic} =~ /flash_error\/v2/) {
			mqtt_flash_error_handler($data{topic}, $data{message});
		}
		elsif ($data{topic} =~ /reset_reason\/v2/) {
			mqtt_reset_reason_handler($data{topic}, $data{message});
		}
		elsif ($data{topic} =~ /disconnect_count\/v2/) {
			mqtt_disconnect_count_handler($data{topic}, $data{message});
		}
		
		# remove data for job
		$redis->del($job_id);
	}
}

# end of main


sub v2_mqtt_sample_handler {
	my ($topic, $message) = @_;

	unless ($topic =~ m!/sample/v\d+/([^/]+)/(\d+)!) {
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
			if (($key, $value, $unit) = $key_value =~ /([^=]*)=(\S+)(?:\s+(.*))?/) {
				# check energy register unit
				if ($key =~ /^e1$/i) {
					if ($unit =~ /^MWh$/i) {
						$value *= 1000;
						$unit = 'kWh';
					}
					if ($unit =~ /^Gj$/i) {
						$value *= 277.77777777778;
						$unit = 'kWh';
					}
				}
				$mqtt_data->{$key} = $value;
			}
		}		
		# save to db
		my $sth = $dbh->prepare(qq[INSERT INTO `samples` (
			`serial`,
			`heap`,
			`flow_temp`,
			`return_flow_temp`,
			`temp_diff`,
			`t3`,
			`flow`,
			`effect`,
			`hours`,
			`volume`,
			`energy`,
			`unix_time`
			) VALUES (] . 
			$dbh->quote($meter_serial) . ',' . 
			$dbh->quote($mqtt_data->{heap}) . ',' . 
			$dbh->quote($mqtt_data->{t1}) . ',' . 
			$dbh->quote($mqtt_data->{t2}) . ',' . 
			$dbh->quote($mqtt_data->{tdif}) . ',' . 
			$dbh->quote($mqtt_data->{t3}) . ',' . 
			$dbh->quote($mqtt_data->{flow1}) . ',' . 
			$dbh->quote($mqtt_data->{effect1}) . ',' . 
			$dbh->quote($mqtt_data->{hr}) . ',' . 
			$dbh->quote($mqtt_data->{v1}) . ',' . 
			$dbh->quote($mqtt_data->{e1}) . ',' .
			$dbh->quote($unix_time) . qq[)]);
		$sth->execute;
		if ($sth->err) {
			syslog('info', $sth->err . ": " . $sth->errstr . " reinserting into redis: " . $topic . " " . $message);
			
			# re-insert to redis
			# Create the next id
			my $id = $redis->incr(join(':',$queue_name, 'id'));
			my $job_id = join(':', $queue_name, $id);

			my %data = (topic => $topic, message => $message);

			# Set the data first
			$redis->hmset($job_id, %data);

			# Then add the job to the queue
			$redis->rpush(join(':', $queue_name, 'queue'), $job_id);
		}
		else {
			# update last_updated time stamp
			my $quoted_meter_serial = $dbh->quote($meter_serial);
			my $quoted_unix_time = $dbh->quote($unix_time);
			$dbh->do(qq[UPDATE meters SET \
							last_updated = $quoted_unix_time \
							WHERE serial = $quoted_meter_serial AND $quoted_unix_time > last_updated]) or warn $!;
			syslog('info', $topic . " " . $message);			
		}
		$sth->finish;
	}
	else {
		# hmac sha256 not ok
		syslog('info', $topic . "hmac error");
		syslog('info', $topic . "\t" . unpack('H*', $message));
	}
	$mqtt_data = undef;
#	print "*** " . tv_interval($t0) . " ***\n";
}

sub v2_mqtt_version_handler {
	my ($topic, $message) = @_;

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
	}
	else {
		# hmac sha256 not ok
		syslog('info', $topic . "hmac error");
		syslog('info', $topic . "\t" . unpack('H*', $message));
	}
}

sub v2_mqtt_status_handler {
	my ($topic, $message) = @_;
	
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
		syslog('info', 'valve_status changed' . " " . $meter_serial . " " . $valve_status);
	}
	else {
		# hmac sha256 not ok
		syslog('info', $topic . "hmac error");
		syslog('info', $topic . "\t" . unpack('H*', $message));
	}
}

sub v2_mqtt_uptime_handler {
	my ($topic, $message) = @_;
	
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
	}
	else {
		# hmac sha256 not ok
		syslog('info', $topic . "hmac error");
		syslog('info', $topic . "\t" . unpack('H*', $message));
	}
}

sub v2_mqtt_ssid_handler {
	my ($topic, $message) = @_;
	
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
	}
	else {
		# hmac sha256 not ok
		syslog('info', $topic . "hmac error");
		syslog('info', $topic . "\t" . unpack('H*', $message));
	}
}

sub v2_mqtt_rssi_handler {
	my ($topic, $message) = @_;
	
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
	}
	else {
		# hmac sha256 not ok
		syslog('info', $topic . "hmac error");
		syslog('info', $topic . "\t" . unpack('H*', $message));
	}
}

sub v2_mqtt_wifi_status_handler {
	my ($topic, $message) = @_;
	
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
	}
	else {
		# hmac sha256 not ok
		syslog('info', $topic . "hmac error");
		syslog('info', $topic . "\t" . unpack('H*', $message));
	}
}

sub v2_mqtt_ap_status_handler {
	my ($topic, $message) = @_;
	
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
	}
	else {
		# hmac sha256 not ok
		syslog('info', $topic . "hmac error");
		syslog('info', $topic . "\t" . unpack('H*', $message));
	}
}

sub v2_mqtt_reset_reason_handler {
	my ($topic, $message) = @_;
	
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
	}
	else {
		# hmac sha256 not ok
		syslog('info', $topic . "hmac error");
		syslog('info', $topic . "\t" . unpack('H*', $message));
	}
}

sub v2_mqtt_scan_result_handler {
	my ($topic, $message) = @_;

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
			`auth_mode`,
			`pairwise_cipher`,
			`group_cipher`,
			`phy_11b`,
			`phy_11g`,
			`phy_11n`,
			`wps`,
			`unix_time`
			) VALUES (] . 
			$dbh->quote($meter_serial) . ',' . 
			$dbh->quote($mqtt_data->{ssid}) . ',' . 
			$dbh->quote($mqtt_data->{bssid}) . ',' . 
			$dbh->quote($mqtt_data->{rssi}) . ',' . 
			$dbh->quote($mqtt_data->{channel}) . ',' . 
			$dbh->quote($mqtt_data->{auth_mode}) . ',' . 
			$dbh->quote($mqtt_data->{pairwise_cipher}) . ',' . 
			$dbh->quote($mqtt_data->{group_cipher}) . ',' . 
			$dbh->quote($mqtt_data->{phy_11b}) . ',' . 
			$dbh->quote($mqtt_data->{phy_11g}) . ',' . 
			$dbh->quote($mqtt_data->{phy_11n}) . ',' . 
			$dbh->quote($mqtt_data->{wps}) . ',' . 
			'UNIX_TIMESTAMP()' . qq[)]);
		$sth->execute;
		if ($sth->err) {
			syslog('info', $sth->err . ": " . $sth->errstr . " reinserting into redis: " . $topic . " " . $message);
			
			# re-insert to redis
			# Create the next id
			my $id = $redis->incr(join(':',$queue_name, 'id'));
			my $job_id = join(':', $queue_name, $id);

			my %data = (topic => $topic, message => $message);

			# Set the data first
			$redis->hmset($job_id, %data);

			# Then add the job to the queue
			$redis->rpush(join(':', $queue_name, 'queue'), $job_id);
		}
		else {
			syslog('info', $topic . " " . $message);
		}	
		$sth->finish;
	}
	else {
		# hmac sha256 not ok
		syslog('info', $topic . "hmac error");
		syslog('info', $topic . "\t" . unpack('H*', $message));
	}
	$mqtt_data = undef;
}

sub mqtt_offline_handler {
	my ($topic, $message) = @_;

	unless ($topic =~ m!/offline/v\d+/([^/]+)!) {
		return;
	}
	$meter_serial = $1;
	$unix_time = time();

	my $quoted_meter_serial = $dbh->quote($meter_serial);
	my $quoted_unix_time = $dbh->quote($unix_time);
	$dbh->do(qq[INSERT INTO `log` (`serial`, `function`, `unix_time`) VALUES ($quoted_meter_serial, 'offline', $quoted_unix_time)]) or warn $!;
	syslog('info', $topic . "\t" . 'offline');
}

sub mqtt_flash_id_handler {
	my ($topic, $message) = @_;

	unless ($topic =~ m!/flash_id/v\d+/([^/]+)/(\d+)!) {
		return;
	}
	$meter_serial = $1;
	$unix_time = $2;

	$flash_id = $crypto->decrypt_topic_message_for_serial($topic, $message, $meter_serial);
	if ($sw_version) {	
		# remove trailing nulls
		$sw_version =~ s/[\x00\s]+$//;
		$sw_version .= '';

		my $quoted_flash_id = $dbh->quote($flash_id);
		my $quoted_meter_serial = $dbh->quote($meter_serial);
		my $quoted_unix_time = $dbh->quote($unix_time);
		$dbh->do(qq[UPDATE meters SET \
						flash_id = $quoted_flash_id, \
						last_updated = $quoted_unix_time \
						WHERE serial = $quoted_meter_serial AND $quoted_unix_time > last_updated]) or warn $!;
		syslog('info', $topic . "\t" . $flash_id);
	}
	else {
		# hmac sha256 not ok
		syslog('info', $topic . "hmac error");
		syslog('info', $topic . "\t" . unpack('H*', $message));
	}
}

sub mqtt_flash_size_handler {
	my ($topic, $message) = @_;

	unless ($topic =~ m!/flash_size/v\d+/([^/]+)/(\d+)!) {
		return;
	}
	$meter_serial = $1;
	$unix_time = $2;

	$flash_size = $crypto->decrypt_topic_message_for_serial($topic, $message, $meter_serial);
	if ($sw_version) {	
		# remove trailing nulls
		$sw_version =~ s/[\x00\s]+$//;
		$sw_version .= '';

		my $quoted_flash_size = $dbh->quote($flash_size);
		my $quoted_meter_serial = $dbh->quote($meter_serial);
		my $quoted_unix_time = $dbh->quote($unix_time);
		$dbh->do(qq[UPDATE meters SET \
						flash_size = $quoted_flash_size, \
						last_updated = $quoted_unix_time \
						WHERE serial = $quoted_meter_serial AND $quoted_unix_time > last_updated]) or warn $!;
		syslog('info', $topic . "\t" . $flash_size);
	}
	else {
		# hmac sha256 not ok
		syslog('info', $topic . "hmac error");
		syslog('info', $topic . "\t" . unpack('H*', $message));
	}
}

sub mqtt_flash_error_handler {
	my ($topic, $message) = @_;
	
	unless ($topic =~ m!/flash_error/v\d+/([^/]+)/(\d+)!) {
		return;
	}
	$meter_serial = $1;
	$unix_time = $2;

	$message =~ /(.{32})(.{16})(.+)/s;
	$message = $crypto->decrypt_topic_message_for_serial($topic, $message, $meter_serial);
	if ($message) {
		# remove trailing nulls
		$message =~ s/[\x00\s]+$//;
		$message .= '';

		my $quoted_flash_error = $dbh->quote($message);
		my $quoted_meter_serial = $dbh->quote($meter_serial);
		my $quoted_unix_time = $dbh->quote($unix_time);
			$dbh->do(qq[INSERT INTO `log` (`serial`, `function`, `param`, `unix_time`) VALUES ($quoted_meter_serial, 'flash_error', $quoted_flash_error, $quoted_unix_time)]) or warn $!;
		syslog('info', $topic . "\t" . 'flash_error');
		
	}
	else {
		# hmac sha256 not ok
		syslog('info', $topic . "hmac error");
		syslog('info', $topic . "\t" . unpack('H*', $message));
	}
}

sub mqtt_reset_reason_handler {
	my ($topic, $message) = @_;
	
	unless ($topic =~ m!/reset_reason/v\d+/([^/]+)/(\d+)!) {
		return;
	}
	$meter_serial = $1;
	$unix_time = $2;

	$message =~ /(.{32})(.{16})(.+)/s;
	$message = $crypto->decrypt_topic_message_for_serial($topic, $message, $meter_serial);
	if ($message) {
		# remove trailing nulls
		$message =~ s/[\x00\s]+$//;
		$message .= '';

		my $quoted_reset_reason = $dbh->quote($message);
		my $quoted_meter_serial = $dbh->quote($meter_serial);
		my $quoted_unix_time = $dbh->quote($unix_time);
		$dbh->do(qq[INSERT INTO `log` (`serial`, `function`, `param`, `unix_time`) VALUES ($quoted_meter_serial, 'reset_reason', $quoted_reset_reason, $quoted_unix_time)]) or warn $!;
		syslog('info', $topic . "\t" . 'reset_reason');			
	}
	else {
		# hmac sha256 not ok
		syslog('info', $topic . "hmac error");
		syslog('info', $topic . "\t" . unpack('H*', $message));
	}
}

sub mqtt_disconnect_count_handler {
	my ($topic, $message) = @_;

	unless ($topic =~ m!/disconnect_count/v\d+/([^/]+)/(\d+)!) {
		return;
	}
	$meter_serial = $1;
	$unix_time = $2;

	$disconnect_count = $crypto->decrypt_topic_message_for_serial($topic, $message, $meter_serial);
	if ($disconnect_count) {	
		# remove trailing nulls
		$disconnect_count =~ s/[\x00\s]+$//;
		$disconnect_count .= '';

		my $quoted_disconnect_count = $dbh->quote($disconnect_count);
		my $quoted_meter_serial = $dbh->quote($meter_serial);
		my $quoted_unix_time = $dbh->quote($unix_time);
		$dbh->do(qq[UPDATE meters SET \
						disconnect_count = $quoted_flash_size, \
						last_updated = $quoted_unix_time \
						WHERE serial = $quoted_meter_serial AND $quoted_unix_time > last_updated]) or warn $!;
		syslog('info', $topic . "\t" . $disconnect_count);
	}
	else {
		# hmac sha256 not ok
		syslog('info', $topic . "hmac error");
		syslog('info', $topic . "\t" . unpack('H*', $message));
	}
}

__END__
