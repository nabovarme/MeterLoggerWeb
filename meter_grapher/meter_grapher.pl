#!/usr/bin/perl -w

use strict;
use Data::Dumper;
use Redis;
use DBI;
use Crypt::Mode::CBC;
use Digest::SHA qw( sha256 hmac_sha256 );
use Encode qw(decode encode FB_DEFAULT);

use Nabovarme::Db;
use Nabovarme::Crypto;
use Nabovarme::Utils;

# Set signal handler for clean manual worker termination
$SIG{INT} = \&sig_int_handler;

log_info("starting...", {-no_script_name => 1});

# Verify runtime Redis infrastructure environment configurations
my $redis_host = $ENV{'REDIS_HOST'}
	or log_die("ERROR: REDIS_HOST environment variable not set", {-no_script_name => 1});

my $redis_port = $ENV{'REDIS_PORT'}
	or log_die("ERROR: REDIS_PORT environment variable not set", {-no_script_name => 1});
my $redis = Redis->new(
	server => "$redis_host:$redis_port",
);

my $queue_name	= 'mqtt';
my $timeout		= 86400;

# --------------------------------------------------
# Intercepts Ctrl+C (SIGINT) to allow graceful script termination.
# --------------------------------------------------
sub sig_int_handler {
	log_info("Caught SIGINT, exiting.", {-no_script_name => 1});
	exit 0;
}

# Establish authoritative database connection
my $dbh;
if ($dbh = Nabovarme::Db->my_connect) {
	$dbh->{'mysql_auto_reconnect'} = 1;
	log_info("Connected to DB", {-no_script_name => 1});
}
else {
	log_die("Cant't connect to DB $!", {-no_script_name => 1});
}

my $crypto = new Nabovarme::Crypto;

# ==================================================
# MAIN MQTT INGESTION LOOP
# ==================================================
# Start MQTT run loop
while (1) {
	# Blocking pop payload from targeted job queue with explicit timeout bounds
	my ($queue, $job_id) = $redis->blpop(join(':', $queue_name, 'queue'), $timeout);
	if ($job_id) {
	
		my %data = $redis->hgetall($job_id);
	
		# Route payloads matching specified namespaces to target handler subroutines
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
		elsif ($data{topic} =~ /set_ap_mesh_pwd\/v2/) {
			mqtt_set_ap_mesh_pwd_handler($data{topic}, $data{message});
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
		
		# Remove data for job after processing
		$redis->del($job_id);
	}
}

# End of main

# --------------------------------------------------
# Decrypts and processes real physical sensor telemetry (flow, energy, volume)
# and commits data points to the historical samples table.
# --------------------------------------------------
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
		# Parse message and strip tail parameters
		$sample =~ s/&$//;
	
		my ($key, $value, $unit);
		my @key_value_list = split(/&/, $sample);
		my $key_value; 
		foreach $key_value (@key_value_list) {
			if (($key, $value, $unit) = $key_value =~ /([^=]*)=(\S+)(?:\s+(.*))?/) {
				# Check energy register unit and normalize to standard kWh metrics
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
		# Save real meter telemetry sample to database
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
			
			# Re-insert to redis: Roll back and recreate token payload in task queue
			my $id = $redis->incr(join(':',$queue_name, 'id'));
			my $job_id = join(':', $queue_name, $id);

			my %data = (topic => $topic, message => $message);

			# Set the data first
			$redis->hmset($job_id, %data);

			# Then add the job to the queue
			$redis->rpush(join(':', $queue_name, 'queue'), $job_id);
		}
		else {
			# Telemetry event verified: last_updated field should be updated (Flag = 1)
			update_meter_field($meter_serial, $unix_time, 'last_updated', $unix_time, 1);
			log_info($topic . " " . $sample, {-no_script_name => 1});			
		}
		$sth->finish;
	}
	else {
		# HMAC SHA256 verification failed
		log_warn($topic . " hmac error, " . (defined $message ? unpack('H*', $message) : 'undef'), {-no_script_name => 1});
	}
}

# --------------------------------------------------
# Tracks and stores the software firmware version metadata of the meter.
# --------------------------------------------------
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
		# Remove trailing nulls
		$sw_version =~ s/[\x00\s]+$//;
		$sw_version .= '';

		# Diagnostic Only: Flagged with 0
		update_meter_field($meter_serial, $unix_time, 'sw_version', $sw_version, 0);

		log_info($topic . "\t" . $sw_version, {-no_script_name => 1});
	}
	else {
		log_warn($topic . " hmac error, " . (defined $message ? unpack('H*', $message) : 'undef'), {-no_script_name => 1});
	}
}

# --------------------------------------------------
# Monitors and logs device specific operational states (e.g. valve open/closed info).
# --------------------------------------------------
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
		# Remove trailing nulls
		$valve_status =~ s/[\x00\s]+$//;
		$valve_status .= '';

		# Diagnostic Only: Flagged with 0
		update_meter_field($meter_serial, $unix_time, 'valve_status', $valve_status, 0);

		log_info($topic . "\t" . $valve_status, {-no_script_name => 1});
	}
	else {
		log_warn($topic . " hmac error, " . (defined $message ? unpack('H*', $message) : 'undef'), {-no_script_name => 1});
	}
}

# --------------------------------------------------
# Updates running device clock heartbeats to track microcontroller uptime.
# --------------------------------------------------
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
		# Remove trailing nulls
		$uptime =~ s/[\x00\s]+$//;
		$uptime .= '';

		# Diagnostic Only: Flagged with 0
		update_meter_field($meter_serial, $unix_time, 'uptime', $uptime, 0);

		log_info($topic . "\t" . $uptime, {-no_script_name => 1});
	}
	else {
		log_warn($topic . " hmac error, " . (defined $message ? unpack('H*', $message) : 'undef'), {-no_script_name => 1});
	}
}

# --------------------------------------------------
# Logs the current network WiFi access point SSID name used by the node.
# --------------------------------------------------
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
		# Remove trailing nulls
		$ssid =~ s/[\x00\s]+$//;
		$ssid .= '';

		# Diagnostic Only: Flagged with 0
		update_meter_field($meter_serial, $unix_time, 'ssid', $ssid, 0);

		log_info($topic . "\t" . $ssid, {-no_script_name => 1});
	}
	else {
		log_warn($topic . " hmac error, " . (defined $message ? unpack('H*', $message) : 'undef'), {-no_script_name => 1});
	}
}

# --------------------------------------------------
# Monitors network link signal characteristics (Received Signal Strength Indicator).
# --------------------------------------------------
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
		# Remove trailing nulls
		$rssi =~ s/[\x00\s]+$//;
		$rssi .= '';

		# Diagnostic Only: Flagged with 0
		update_meter_field($meter_serial, $unix_time, 'rssi', $rssi, 0);

		log_info($topic . "\t" . $rssi, {-no_script_name => 1});
	}
	else {
		log_warn($topic . " hmac error, " . (defined $message ? unpack('H*', $message) : 'undef'), {-no_script_name => 1});
	}
}

# --------------------------------------------------
# Logs wireless connectivity internal machine states and connection flags.
# --------------------------------------------------
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
		# Remove trailing nulls
		$wifi_status =~ s/[\x00\s]+$//;
		$wifi_status .= '';

		# Diagnostic Only: Flagged with 0
		update_meter_field($meter_serial, $unix_time, 'wifi_status', $wifi_status, 0);

		log_info($topic . "\t" . $wifi_status, {-no_script_name => 1});
	}
	else {
		log_warn($topic . " hmac error, " . (defined $message ? unpack('H*', $message) : 'undef'), {-no_script_name => 1});
	}
}

# --------------------------------------------------
# Logs the state of the local soft access point capability when operating in mesh.
# --------------------------------------------------
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
		# Remove trailing nulls
		$ap_status =~ s/[\x00\s]+$//;
		$ap_status .= '';

		# Diagnostic Only: Flagged with 0
		update_meter_field($meter_serial, $unix_time, 'ap_status', $ap_status, 0);
		
		log_info($topic . "\t" . $ap_status, {-no_script_name => 1});
	}
	else {
		log_warn($topic . " hmac error, " . (defined $message ? unpack('H*', $message) : 'undef'), {-no_script_name => 1});
	}
}

# --------------------------------------------------
# Updates stored decrypted network pairing tokens across adjacent mesh nodes.
# --------------------------------------------------
sub mqtt_set_ap_mesh_pwd_handler {
	my ($topic, $message) = @_;
	my ($meter_serial, $unix_time);

	unless ($topic =~ m!/set_ap_mesh_pwd/v\d+/([^/]+)/(\d+)!) {
		return;
	}
	$meter_serial = $1;
	$unix_time = $2;

	my $mesh_pwd = $crypto->decrypt_topic_message_for_serial($topic, $message, $meter_serial);
	if (defined $mesh_pwd) {
		# Remove trailing nulls
		$mesh_pwd =~ s/[\x00\s]+$//;
		$mesh_pwd .= '';

		# Diagnostic Only: Flagged with 0
		update_meter_field($meter_serial, $unix_time, 'mesh_pwd', $mesh_pwd, 0);

		log_info($topic . "\tmesh_pwd updated", {-no_script_name => 1});
	}
	else {
		log_warn($topic . " hmac error, " . (defined $message ? unpack('H*', $message) : 'undef'), {-no_script_name => 1});
	}
}

# --------------------------------------------------
# Parses environment wireless scan reports into the relational wifi_scan table.
# --------------------------------------------------
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
		# Parse message
		$scan_result =~ s/&$//;

		my ($key, $value);
		my @key_value_list = split(/&/, $scan_result);
		my $key_value; 
		foreach $key_value (@key_value_list) {
			if (($key, $value) = $key_value =~ /([^=]*)=(.*)/) {
				$mqtt_data->{$key} = $value;
			}
		}		

		# Safety Truncation Check to prevent DB column sizing overflows
		if (defined $mqtt_data->{ssid} && length($mqtt_data->{ssid}) > 64) {
			log_warn("Over-sized raw ssid string detected (" . length($mqtt_data->{ssid}) . " bytes). Truncating payload parameter down to 64 bytes.", {-no_script_name => 1});
			$mqtt_data->{ssid} = substr($mqtt_data->{ssid}, 0, 64);
		}

		# Store raw SSID for Wi-Fi connection
		my $ssid_raw = $mqtt_data->{ssid};
		my $ssid = decode_ssid($ssid_raw);

		# Safety Truncation Check for decoded representation
		if (defined $ssid && length($ssid) > 64) {
			$ssid = substr($ssid, 0, 64);
		}

		# Save scan attributes to database
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
			
			# Re-insert to redis upon database failure
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
		log_warn($topic . " hmac error, " . (defined $message ? unpack('H*', $message) : 'undef'), {-no_script_name => 1});
	}
}

# --------------------------------------------------
# Logs an explicit offline notice triggered directly from broker disconnects.
# --------------------------------------------------
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

# --------------------------------------------------
# Logs hardware identifier registration indexes for tracking the physical MCU.
# --------------------------------------------------
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
		# Remove trailing nulls
		$chip_id =~ s/[\x00\s]+$//;
		$chip_id .= '';

		# Diagnostic Only: Flagged with 0
		update_meter_field($meter_serial, $unix_time, 'chip_id', $chip_id, 0);

		log_info($topic . "\t" . $chip_id, {-no_script_name => 1});
	}
	else {
		log_warn($topic . " hmac error, " . (defined $message ? unpack('H*', $message) : 'undef'), {-no_script_name => 1});
	}
}

# --------------------------------------------------
# Logs structural memory board identifiers from onboard tracking profiles.
# --------------------------------------------------
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
		# Remove trailing nulls
		$flash_id =~ s/[\x00\s]+$//;
		$flash_id .= '';

		# Diagnostic Only: Flagged with 0
		update_meter_field($meter_serial, $unix_time, 'flash_id', $flash_id, 0);

		log_info($topic . "\t" . $flash_id, {-no_script_name => 1});
	}
	else {
		log_warn($topic . " hmac error, " . (defined $message ? unpack('H*', $message) : 'undef'), {-no_script_name => 1});
	}
}

# --------------------------------------------------
# Verifies internal storage allocation specifications configured on the node.
# --------------------------------------------------
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
		# Remove trailing nulls
		$flash_size =~ s/[\x00\s]+$//;
		$flash_size .= '';

		# Diagnostic Only: Flagged with 0
		update_meter_field($meter_serial, $unix_time, 'flash_size', $flash_size, 0);

		log_info($topic . "\t" . $flash_size, {-no_script_name => 1});
	}
	else {
		log_warn($topic . " hmac error, " . (defined $message ? unpack('H*', $message) : 'undef'), {-no_script_name => 1});
	}
}

# --------------------------------------------------
# Captures memory component exceptions into the core operations event log.
# --------------------------------------------------
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
		# Remove trailing nulls
		$flash_error =~ s/[\x00\s]+$//;
		$flash_error .= '';

		my $quoted_flash_error = $dbh->quote($flash_error);
		my $quoted_meter_serial = $dbh->quote($meter_serial);
		my $quoted_unix_time = $dbh->quote($unix_time);
		$dbh->do(qq[INSERT INTO `log` (`serial`, `function`, `param`, `unix_time`) VALUES ($quoted_meter_serial, 'flash_error', $quoted_flash_error, $quoted_unix_time)]) or log_warn($! . ". " . $DBI::errstr, {-no_script_name => 1});
		log_info($topic . "\t" . 'flash_error', {-no_script_name => 1});
	}
	else {
		log_warn($topic . " hmac error, " . (defined $message ? unpack('H*', $message) : 'undef'), {-no_script_name => 1});
	}
}

# --------------------------------------------------
# Logs physical or system crash reset causes received from automated node reboots.
# --------------------------------------------------
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
		# Remove trailing nulls
		$reset_reason =~ s/[\x00\s]+$//;
		$reset_reason .= '';

		my $quoted_reset_reason = $dbh->quote($reset_reason);
		my $quoted_meter_serial = $dbh->quote($meter_serial);
		my $quoted_unix_time = $dbh->quote($unix_time);
		$dbh->do(qq[INSERT INTO `log` (`serial`, `function`, `param`, `unix_time`) VALUES ($quoted_meter_serial, 'reset_reason', $quoted_reset_reason, $quoted_unix_time)]) or log_warn($! . ". " . $DBI::errstr, {-no_script_name => 1});
		log_info($topic . "\t" . 'reset_reason', {-no_script_name => 1});			
	}
	else {
		log_warn($topic . " hmac error, " . (defined $message ? unpack('H*', $message) : 'undef'), {-no_script_name => 1});
	}
}

# --------------------------------------------------
# Processes diagnostic latency indicators (ping response times, loss percentage, disconnects).
# --------------------------------------------------
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
		# Parse message
		$network_quality =~ s/[\x00\s]+$//;
		$network_quality .= '';
		$network_quality =~ s/&$//;
	
		my ($key, $value);
		my @key_value_list = split(/&/, $network_quality);
		my $key_value; 
		foreach $key_value (@key_value_list) {
			if (($key, $value) = $key_value =~ /([^=]*)=(.*)/) {
				$mqtt_data->{$key} = $value;
			}
		}		

		# Save diagnostics without updating the master 'last_updated' tracking timestamp (Flagged as 0)
		update_meter_field($meter_serial, $unix_time, 'ping_response_time', $mqtt_data->{ping_response_time}, 0);
		update_meter_field($meter_serial, $unix_time, 'ping_average_packet_loss', $mqtt_data->{ping_average_packet_loss}, 0);
		update_meter_field($meter_serial, $unix_time, 'disconnect_count', $mqtt_data->{disconnect_count}, 0);

		log_info($topic . "\t" . $network_quality, {-no_script_name => 1});
	}
	else {
		log_warn($topic . " hmac error, " . (defined $message ? unpack('H*', $message) : 'undef'), {-no_script_name => 1});
	}
}

use Encode qw(decode);

# --------------------------------------------------
# Safe translation wrapper formatting SSID byte strings to clean internal UTF-8.
# --------------------------------------------------
sub decode_ssid {
	my ($raw) = @_;
	return undef unless defined $raw;
	
	# Decode UTF-8 bytes into Perl internal UTF-8 string
	my $ssid = decode('UTF-8', $raw, Encode::FB_DEFAULT);
	
	# Remove control chars
	$ssid =~ s/[\x00-\x1F\x7F]//g;
	
	return $ssid;
}

# --------------------------------------------------
# Unified entry point handling database column modifications inside the meters dataset.
# Accepts an explicit flag toggle determining if the master metadata indicator 
# ('last_updated') should step forward or stay frozen to isolate active downtime checks.
# --------------------------------------------------
sub update_meter_field {
	my ($serial, $unix_time, $field, $value, $update_timestamp) = @_;

	my $quoted_serial = $dbh->quote($serial);
	my $quoted_value  = $dbh->quote($value);
	my $quoted_time   = $dbh->quote($unix_time);

	my $sql;
	if ($update_timestamp) {
		# Core telemetric update path (moves last_updated forward)
		$sql = qq[UPDATE meters SET \
					$field = $quoted_value, \
					last_updated = $quoted_time \
					WHERE serial = $quoted_serial \
						AND $quoted_time > last_updated];
	} else {
		# Peripheral/diagnostics path (safely isolates the last_updated monitoring timeline)
		$sql = qq[UPDATE meters SET \
					$field = $quoted_value \
					WHERE serial = $quoted_serial];
	}

	$dbh->do($sql) or log_warn($! . ". " . $DBI::errstr, {-no_script_name => 1});
}

__END__
