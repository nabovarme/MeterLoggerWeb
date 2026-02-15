#!/usr/bin/perl -w

use strict;
use Data::Dumper;
use Redis;
use DBI;
use Crypt::Mode::CBC;
use Digest::SHA qw( sha256 hmac_sha256 );
use Encode qw(decode FB_CROAK FB_DEFAULT);

use Nabovarme::Db;
use Nabovarme::Crypto;
use Nabovarme::Utils;

$SIG{INT} = \&sig_int_handler;

log_info("starting...", {-no_script_name => 1});

my $redis_host = $ENV{'REDIS_HOST'}
	or log_die("ERROR: REDIS_HOST environment variable not set", {-no_script_name => 1});

my $redis_port = $ENV{'REDIS_PORT'}
	or log_die("ERROR: REDIS_PORT environment variable not set", {-no_script_name => 1});
my $redis = Redis->new(
	server => "$redis_host:$redis_port",
);

my $queue_name	= 'mqtt';
my $timeout		= 86400;

sub sig_int_handler {
	log_info("Caught SIGINT, exiting.", {-no_script_name => 1});
	exit 0;
}
# connect to db
my $dbh;
if ($dbh = Nabovarme::Db->my_connect) {
	$dbh->{'mysql_auto_reconnect'} = 1;
	log_info("Connected to DB", {-no_script_name => 1});
}
else {
	log_die("Cant't connect to DB $!", {-no_script_name => 1});
}

my $crypto = new Nabovarme::Crypto;

# start mqtt run loop
while (1) {
	my ($queue, $job_id) = $redis->blpop(join(':', $queue_name, 'queue'), $timeout);
	if ($job_id) {
	
		my %data = $redis->hgetall($job_id);
	
		if ($data{topic} =~ /sample\/v2\//) {
			mqtt_sample_handler($data{topic}, $data{message});
		}
		elsif ($data{topic} =~ /version\/v2/) {
			mqtt_version_handler($data{topic}, $data{message});
		}
		elsif ($data{topic} =~ /status\/v2/) {
			mqtt_status_handler($data{topic}, $data{message});
		}
		elsif ($data{topic} =~ /uptime\/v2/) {
			mqtt_uptime_handler($data{topic}, $data{message});
		}
		elsif ($data{topic} =~ /ssid\/v2/) {
			mqtt_ssid_handler($data{topic}, $data{message});
		}
		elsif ($data{topic} =~ /rssi\/v2/) {
			mqtt_rssi_handler($data{topic}, $data{message});
		}
		elsif ($data{topic} =~ /wifi_status\/v2/) {
			mqtt_wifi_status_handler($data{topic}, $data{message});
		}
		elsif ($data{topic} =~ /ap_status\/v2/) {
			mqtt_ap_status_handler($data{topic}, $data{message});
		}
		elsif ($data{topic} =~ /scan_result\/v2/) {
			mqtt_scan_result_handler($data{topic}, $data{message});
		}
		elsif ($data{topic} =~ /offline\/v1\//) {
			mqtt_offline_handler($data{topic}, $data{message});
		}
		elsif ($data{topic} =~ /chip_id\/v2/) {
			mqtt_chip_id_handler($data{topic}, $data{message});
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
		elsif ($data{topic} =~ /network_quality\/v2/) {
			mqtt_network_quality_handler($data{topic}, $data{message});
		}
		
		# remove data for job
		$redis->del($job_id);
	}
}

# end of main


sub mqtt_sample_handler {
	my ($topic, $message) = @_;
	my $mqtt_data = {};
	my ($meter_serial, $unix_time);

	unless ($topic =~ m!/sample/v\d+/([^/]+)/(\d+)!) {
		return;
	}	
	$meter_serial = $1;
	$unix_time = $2;

	my $sample = $crypto->decrypt_topic_message_for_serial($topic, $message, $meter_serial);
	if (defined $sample) {	
		# parse message
		$sample =~ s/&$//;
	
		my ($key, $value, $unit);
		my @key_value_list = split(/&/, $sample);
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
			log_warn($sth->err . ": " . $sth->errstr . " reinserting into redis: " . $topic . " " . $message, {-no_script_name => 1});
			
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
							WHERE serial = $quoted_meter_serial AND $quoted_unix_time > last_updated]) or log_warn($! . ". " . $DBI::errstr, {-no_script_name => 1});
			log_info($topic . " " . $sample, {-no_script_name => 1});			
		}
		$sth->finish;
	}
	else {
		# hmac sha256 not ok
		log_warn($topic . " hmac error, " . (defined $message ? unpack('H*', $message) : 'undef'), {-no_script_name => 1});
	}
}

sub mqtt_version_handler {
	my ($topic, $message) = @_;
	my ($meter_serial, $unix_time);

	unless ($topic =~ m!/version/v\d+/([^/]+)/(\d+)!) {
		return;
	}
	$meter_serial = $1;
	$unix_time = $2;

	my $sw_version = $crypto->decrypt_topic_message_for_serial($topic, $message, $meter_serial);
	if (defined $sw_version) {	
		# remove trailing nulls
		$sw_version =~ s/[\x00\s]+$//;
		$sw_version .= '';

		update_meter_field($meter_serial, $unix_time, 'sw_version', $sw_version);

		log_info($topic . "\t" . $sw_version, {-no_script_name => 1});
	}
	else {
		# hmac sha256 not ok
		log_warn($topic . " hmac error, " . (defined $message ? unpack('H*', $message) : 'undef'), {-no_script_name => 1});
	}
}

sub mqtt_status_handler {
	my ($topic, $message) = @_;
	my ($meter_serial, $unix_time);
	
	unless ($topic =~ m!/status/v\d+/([^/]+)/(\d+)!) {
		return;
	}
	$meter_serial = $1;
	$unix_time = $2;

	my $valve_status = $crypto->decrypt_topic_message_for_serial($topic, $message, $meter_serial);
	if (defined $valve_status) {	
		# remove trailing nulls
		$valve_status =~ s/[\x00\s]+$//;
		$valve_status .= '';

		update_meter_field($meter_serial, $unix_time, 'valve_status', $valve_status);

		log_info($topic . "\t" . $valve_status, {-no_script_name => 1});
	}
	else {
		# hmac sha256 not ok
		log_warn($topic . " hmac error, " . (defined $message ? unpack('H*', $message) : 'undef'), {-no_script_name => 1});
	}
}

sub mqtt_uptime_handler {
	my ($topic, $message) = @_;
	my ($meter_serial, $unix_time);
	
	unless ($topic =~ m!/uptime/v\d+/([^/]+)/(\d+)!) {
		return;
	}
	$meter_serial = $1;
	$unix_time = $2;
	
	my $uptime = $crypto->decrypt_topic_message_for_serial($topic, $message, $meter_serial);
	if (defined $uptime) {	
		# remove trailing nulls
		$uptime =~ s/[\x00\s]+$//;
		$uptime .= '';

		update_meter_field($meter_serial, $unix_time, 'uptime', $uptime);

		log_info($topic . "\t" . $uptime, {-no_script_name => 1});
	}
	else {
		# hmac sha256 not ok
		log_warn($topic . " hmac error, " . (defined $message ? unpack('H*', $message) : 'undef'), {-no_script_name => 1});
	}
}

sub mqtt_ssid_handler {
	my ($topic, $message) = @_;
	my ($meter_serial, $unix_time);
	
	unless ($topic =~ m!/ssid/v\d+/([^/]+)/(\d+)!) {
		return;
	}
	$meter_serial = $1;
	$unix_time = $2;
	
	my $ssid = $crypto->decrypt_topic_message_for_serial($topic, $message, $meter_serial);
	if (defined $ssid) {	
		# remove trailing nulls
		$ssid =~ s/[\x00\s]+$//;
		$ssid .= '';

		update_meter_field($meter_serial, $unix_time, 'ssid', $ssid);

		log_info($topic . "\t" . $ssid, {-no_script_name => 1});
	}
	else {
		# hmac sha256 not ok
		log_warn($topic . " hmac error, " . (defined $message ? unpack('H*', $message) : 'undef'), {-no_script_name => 1});
	}
}

sub mqtt_rssi_handler {
	my ($topic, $message) = @_;
	my ($meter_serial, $unix_time);
	
	unless ($topic =~ m!/rssi/v\d+/([^/]+)/(\d+)!) {
		return;
	}
	$meter_serial = $1;
	$unix_time = $2;
	
	my $rssi = $crypto->decrypt_topic_message_for_serial($topic, $message, $meter_serial);
	if (defined $rssi) {	
		# remove trailing nulls
		$rssi =~ s/[\x00\s]+$//;
		$rssi .= '';

		update_meter_field($meter_serial, $unix_time, 'rssi', $rssi);

		log_info($topic . "\t" . $rssi, {-no_script_name => 1});
	}
	else {
		# hmac sha256 not ok
		log_warn($topic . " hmac error, " . (defined $message ? unpack('H*', $message) : 'undef'), {-no_script_name => 1});
	}
}

sub mqtt_wifi_status_handler {
	my ($topic, $message) = @_;
	my ($meter_serial, $unix_time);
	
	unless ($topic =~ m!/wifi_status/v\d+/([^/]+)/(\d+)!) {
		return;
	}
	$meter_serial = $1;
	$unix_time = $2;
	
	my $wifi_status = $crypto->decrypt_topic_message_for_serial($topic, $message, $meter_serial);
	if (defined $wifi_status) {	
		# remove trailing nulls
		$wifi_status =~ s/[\x00\s]+$//;
		$wifi_status .= '';

		update_meter_field($meter_serial, $unix_time, 'wifi_status', $wifi_status);

		log_info($topic . "\t" . $wifi_status, {-no_script_name => 1});
	}
	else {
		# hmac sha256 not ok
		log_warn($topic . " hmac error, " . (defined $message ? unpack('H*', $message) : 'undef'), {-no_script_name => 1});
	}
}

sub mqtt_ap_status_handler {
	my ($topic, $message) = @_;
	my ($meter_serial, $unix_time);
	
	unless ($topic =~ m!/ap_status/v\d+/([^/]+)/(\d+)!) {
		return;
	}
	$meter_serial = $1;
	$unix_time = $2;
	
	my $ap_status = $crypto->decrypt_topic_message_for_serial($topic, $message, $meter_serial);
	if (defined $ap_status) {	
		# remove trailing nulls
		$ap_status =~ s/[\x00\s]+$//;
		$ap_status .= '';

		update_meter_field($meter_serial, $unix_time, 'ap_status', $ap_status);
		
		log_info($topic . "\t" . $ap_status, {-no_script_name => 1});
	}
	else {
		# hmac sha256 not ok
		log_warn($topic . " hmac error, " . (defined $message ? unpack('H*', $message) : 'undef'), {-no_script_name => 1});
	}
}

sub mqtt_scan_result_handler {
	my ($topic, $message) = @_;
	my ($meter_serial, $unix_time);
	my $mqtt_data = {};

	unless ($topic =~ m!/scan_result/v\d+/([^/]+)/(\d+)!) {
		return;
	}
	
	$meter_serial = $1;
	$unix_time = $2;

	my $scan_result = $crypto->decrypt_topic_message_for_serial($topic, $message, $meter_serial);
	if (defined $scan_result) {	
		# parse message
		$scan_result =~ s/&$//;

		my ($key, $value);
		my @key_value_list = split(/&/, $scan_result);
		my $key_value; 
		foreach $key_value (@key_value_list) {
			if (($key, $value) = $key_value =~ /([^=]*)=(.*)/) {
				$mqtt_data->{$key} = $value;
			}
		}		

		# store raw SSID for Wi-Fi connection
		my $ssid_raw = $mqtt_data->{ssid};
		my $ssid = decode_ssid($ssid_raw);

		# save to db
		my $sth = $dbh->prepare(qq[INSERT INTO `wifi_scan` (
			`serial`,
			`ssid_raw`,
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
			$dbh->quote($ssid_raw) . ',' .
			$dbh->quote($ssid) . ',' .
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
			log_warn($sth->err . ": " . $sth->errstr . " reinserting into redis: " . $topic . " " . $message, {-no_script_name => 1});
			
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
			log_info($topic . " " . $scan_result, {-no_script_name => 1});
		}	
		$sth->finish;
	}
	else {
		# hmac sha256 not ok
		log_warn($topic . " hmac error, " . (defined $message ? unpack('H*', $message) : 'undef'), {-no_script_name => 1});
	}
}

sub mqtt_offline_handler {
	my ($topic, $message) = @_;
	my ($meter_serial, $unix_time);

	unless ($topic =~ m!/offline/v\d+/([^/]+)!) {
		return;
	}
	$meter_serial = $1;
	$unix_time = time();

	my $quoted_meter_serial = $dbh->quote($meter_serial);
	my $quoted_unix_time = $dbh->quote($unix_time);
	$dbh->do(qq[INSERT INTO `log` (`serial`, `function`, `unix_time`) VALUES ($quoted_meter_serial, 'offline', $quoted_unix_time)]) or log_warn($! . ". " . $DBI::errstr, {-no_script_name => 1});
	log_warn($topic . "\t" . 'offline', {-no_script_name => 1});
}

sub mqtt_chip_id_handler {
	my ($topic, $message) = @_;
	my ($meter_serial, $unix_time);

	unless ($topic =~ m!/chip_id/v\d+/([^/]+)/(\d+)!) {
		return;
	}
	$meter_serial = $1;
	$unix_time = $2;

	my $chip_id = $crypto->decrypt_topic_message_for_serial($topic, $message, $meter_serial);
	if (defined $chip_id) {	
		# remove trailing nulls
		$chip_id =~ s/[\x00\s]+$//;
		$chip_id .= '';

		update_meter_field($meter_serial, $unix_time, 'chip_id', $chip_id);

		log_info($topic . "\t" . $chip_id, {-no_script_name => 1});
	}
	else {
		# hmac sha256 not ok
		log_warn($topic . " hmac error, " . (defined $message ? unpack('H*', $message) : 'undef'), {-no_script_name => 1});
	}
}

sub mqtt_flash_id_handler {
	my ($topic, $message) = @_;
	my ($meter_serial, $unix_time);

	unless ($topic =~ m!/flash_id/v\d+/([^/]+)/(\d+)!) {
		return;
	}
	$meter_serial = $1;
	$unix_time = $2;

	my $flash_id = $crypto->decrypt_topic_message_for_serial($topic, $message, $meter_serial);
	if (defined $flash_id) {	
		# remove trailing nulls
		$flash_id =~ s/[\x00\s]+$//;
		$flash_id .= '';

		update_meter_field($meter_serial, $unix_time, 'flash_id', $flash_id);

		log_info($topic . "\t" . $flash_id, {-no_script_name => 1});
	}
	else {
		# hmac sha256 not ok
		log_warn($topic . " hmac error, " . (defined $message ? unpack('H*', $message) : 'undef'), {-no_script_name => 1});
	}
}

sub mqtt_flash_size_handler {
	my ($topic, $message) = @_;
	my ($meter_serial, $unix_time);

	unless ($topic =~ m!/flash_size/v\d+/([^/]+)/(\d+)!) {
		return;
	}
	$meter_serial = $1;
	$unix_time = $2;

	my $flash_size = $crypto->decrypt_topic_message_for_serial($topic, $message, $meter_serial);
	if (defined $flash_size) {	
		# remove trailing nulls
		$flash_size =~ s/[\x00\s]+$//;
		$flash_size .= '';

		update_meter_field($meter_serial, $unix_time, 'flash_size', $flash_size);

		log_info($topic . "\t" . $flash_size, {-no_script_name => 1});
	}
	else {
		# hmac sha256 not ok
		log_warn($topic . " hmac error, " . (defined $message ? unpack('H*', $message) : 'undef'), {-no_script_name => 1});
	}
}

sub mqtt_flash_error_handler {
	my ($topic, $message) = @_;
	my ($meter_serial, $unix_time);
	
	unless ($topic =~ m!/flash_error/v\d+/([^/]+)/(\d+)!) {
		return;
	}
	$meter_serial = $1;
	$unix_time = $2;

	my $flash_error = $crypto->decrypt_topic_message_for_serial($topic, $message, $meter_serial);
	if (defined $flash_error) {
		# remove trailing nulls
		$flash_error =~ s/[\x00\s]+$//;
		$flash_error .= '';

		my $quoted_flash_error = $dbh->quote($flash_error);
		my $quoted_meter_serial = $dbh->quote($meter_serial);
		my $quoted_unix_time = $dbh->quote($unix_time);
			$dbh->do(qq[INSERT INTO `log` (`serial`, `function`, `param`, `unix_time`) VALUES ($quoted_meter_serial, 'flash_error', $quoted_flash_error, $quoted_unix_time)]) or log_warn($! . ". " . $DBI::errstr, {-no_script_name => 1});
		log_info($topic . "\t" . 'flash_error', {-no_script_name => 1});
		
	}
	else {
		# hmac sha256 not ok
		log_warn($topic . " hmac error, " . (defined $message ? unpack('H*', $message) : 'undef'), {-no_script_name => 1});
	}
}

sub mqtt_reset_reason_handler {
	my ($topic, $message) = @_;
	my ($meter_serial, $unix_time);
	
	unless ($topic =~ m!/reset_reason/v\d+/([^/]+)/(\d+)!) {
		return;
	}
	$meter_serial = $1;
	$unix_time = $2;

	my $reset_reason = $crypto->decrypt_topic_message_for_serial($topic, $message, $meter_serial);
	if (defined $reset_reason) {
		# remove trailing nulls
		$reset_reason =~ s/[\x00\s]+$//;
		$reset_reason .= '';

		my $quoted_reset_reason = $dbh->quote($reset_reason);
		my $quoted_meter_serial = $dbh->quote($meter_serial);
		my $quoted_unix_time = $dbh->quote($unix_time);
		$dbh->do(qq[INSERT INTO `log` (`serial`, `function`, `param`, `unix_time`) VALUES ($quoted_meter_serial, 'reset_reason', $quoted_reset_reason, $quoted_unix_time)]) or log_warn($! . ". " . $DBI::errstr, {-no_script_name => 1});
		log_info($topic . "\t" . 'reset_reason', {-no_script_name => 1});			
	}
	else {
		# hmac sha256 not ok
		log_warn($topic . " hmac error, " . (defined $message ? unpack('H*', $message) : 'undef'), {-no_script_name => 1});
	}
}

sub mqtt_network_quality_handler {
	my ($topic, $message) = @_;
	my ($meter_serial, $unix_time);
	my $mqtt_data = {};

	unless ($topic =~ m!/network_quality/v\d+/([^/]+)/(\d+)!) {
		return;
	}
	$meter_serial = $1;
	$unix_time = $2;

	my $network_quality = $crypto->decrypt_topic_message_for_serial($topic, $message, $meter_serial);
	if (defined $network_quality) {	
		# parse message
		# remove trailing nulls
		$network_quality =~ s/[\x00\s]+$//;
		$network_quality .= '';

		$network_quality =~ s/&$//;
	
		my ($key, $value, $unit);
		my @key_value_list = split(/&/, $network_quality);
		my $key_value; 
		foreach $key_value (@key_value_list) {
			if (($key, $value) = $key_value =~ /([^=]*)=(.*)/) {
				$mqtt_data->{$key} = $value;
			}
		}		

		my $quoted_meter_serial = $dbh->quote($meter_serial);
		my $quoted_unix_time = $dbh->quote($unix_time);

		$dbh->do(qq[UPDATE meters SET \
						ping_response_time = ] . $dbh->quote($mqtt_data->{ping_response_time}) . qq[, \
						ping_average_packet_loss = ] . $dbh->quote($mqtt_data->{ping_average_packet_loss}) . qq[, \
						disconnect_count = ] . $dbh->quote($mqtt_data->{disconnect_count}) . qq[, \
						last_updated = $quoted_unix_time \
						WHERE serial = $quoted_meter_serial AND $quoted_unix_time > last_updated]) or log_warn($! . ". " . $DBI::errstr, {-no_script_name => 1});
		log_info($topic . "\t" . $network_quality, {-no_script_name => 1});
	}
	else {
		# hmac sha256 not ok
		log_warn($topic . " hmac error, " . (defined $message ? unpack('H*', $message) : 'undef'), {-no_script_name => 1});
	}
}

sub decode_ssid {
	my ($raw) = @_;

	return undef unless defined $raw;

	my $ssid;

	# 1) Try strict UTF-8
	eval {
		$ssid = decode('UTF-8', $raw, FB_CROAK);
	};

	# 2) Fallback to Latin-1 (never fails)
	if ($@) {
		$ssid = decode('ISO-8859-1', $raw, FB_DEFAULT);
	}

	# 3) Remove control characters
	$ssid =~ s/[\x00-\x1F\x7F]//g;

	return $ssid;
}

sub update_meter_field {
	my ($serial, $unix_time, $field, $value) = @_;

	my $quoted_serial = $dbh->quote($serial);
	my $quoted_time = $dbh->quote($unix_time);
	my $quoted_value = $dbh->quote($value);

	$dbh->do(qq[UPDATE meters SET \
				$field = $quoted_value, \
				last_updated = $quoted_time \
				WHERE serial = $quoted_serial \
					AND $quoted_time > last_updated]
	) or log_warn($! . ". " . $DBI::errstr, {-no_script_name => 1});
}

__END__
