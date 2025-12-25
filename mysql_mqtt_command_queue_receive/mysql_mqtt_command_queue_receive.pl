#!/usr/bin/perl -w

use strict;
use warnings;
use Data::Dumper;
use Net::MQTT::Simple;
use DBI;
use Crypt::Mode::CBC;
use Digest::SHA qw( sha256 hmac_sha256 );
use Config::Simple;
use Time::HiRes qw( gettimeofday tv_interval );

use Nabovarme::Db;
use Nabovarme::Utils;

# --- Constants ---
use constant CONFIG_FILE       => '/etc/Nabovarme.conf';
use constant CACHE_DEFAULT_SEC => 3600;        # default 1 hour

$| = 1;  # Autoflush STDOUT

# --- Config ---
my $config = new Config::Simple(CONFIG_FILE)
	or log_die(Config::Simple->error(), {-no_script_name => 1});
my $mqtt_host = $config->param('mqtt_host');
my $mqtt_port = $config->param('mqtt_port');

my $config_cached_time = $config->param('cached_time') || CACHE_DEFAULT_SEC;

$SIG{INT} = \&sig_int_handler;

my ($dbh, $sth, $d);
my $key_cache = {};

my $subscribe_mqtt = Net::MQTT::Simple->new("$mqtt_host:$mqtt_port");

sub sig_int_handler {
	$subscribe_mqtt->disconnect();
	log_die("Interrupted", {-no_script_name => 1});
}

# --------------------
# MQTT message handler
# --------------------
sub mqtt_handler {
	my ($topic, $message) = @_;
	my $t0 = [gettimeofday()];

	# Extract meter_serial and unix_time
	unless ($topic =~ m!/[^/]+/v2/([^/]+)/(\d+)!) {
		return;
	}
	my $meter_serial = $1;
	my $unix_time = $2;

	# Only react to meters with commands in queue
	$sth = $dbh->prepare(qq[SELECT serial FROM command_queue \
		WHERE serial = ] . $dbh->quote($meter_serial) . qq[ \
		LIMIT 1 \
	]);
	$sth->execute;
	
	return unless $sth->rows;

	# Extract mac, iv, ciphertext
	my $mac        = substr($message, 0, 32);
	my $iv         = substr($message, 32, 16);
	my $ciphertext = substr($message, 48);

	# Extract function from topic
	my ($function) = $topic =~ m!/([^/]+)!;
	return if $function =~ /^config$/i;

	# Get AES key from cache or DB
	my $key = '';
	if (exists($key_cache->{$meter_serial}) && ($key_cache->{$meter_serial}->{cached_time} > (time() - $config_cached_time))) {
		$key = $key_cache->{$meter_serial}->{key};
	} else {
		$sth = $dbh->prepare(qq[SELECT `key` FROM meters \
			WHERE serial = ] . $dbh->quote($meter_serial) . qq[ \
			LIMIT 1 \
		]);
		$sth->execute;
		if ($sth->rows) {
			$d = $sth->fetchrow_hashref;
			$key_cache->{$meter_serial}->{key} = $d->{key};
			$key_cache->{$meter_serial}->{cached_time} = time();
			$key = $d->{key} || log_warn("No AES key found", {-no_script_name => 1});
		}
	}

	return unless $key;

	# --------------------
	# scan_result special case
	# --------------------
	if ($function =~ /^scan_result$/i) {
		debug_print("Received MQTT reply from $meter_serial: $function, deleting from MySQL queue");
		$dbh->do(qq[DELETE FROM command_queue \
			WHERE serial = ] . $dbh->quote($meter_serial) . qq[ \
			AND function = 'scan' \
		]) or log_warn($DBI::errstr, {-no_script_name => 1});
		return;
	}

	# Decrypt message
	my $sha256 = sha256(pack('H*', $key));
	my $aes_key = substr($sha256, 0, 16);
	my $hmac_sha256_key = substr($sha256, 16, 16);

	if ($mac eq hmac_sha256($topic . $iv . $ciphertext, $hmac_sha256_key)) {
		my $m = Crypt::Mode::CBC->new('AES');
		my $cleartext = $m->decrypt($ciphertext, $aes_key, $iv);
		$cleartext =~ s/[\x00\s]+$//; # remove trailing nulls

		# Only react to functions we have sent commands for
		$sth = $dbh->prepare(qq[SELECT serial FROM command_queue \
			WHERE serial = ] . $dbh->quote($meter_serial) . qq[ \
			AND function = ] . $dbh->quote($function) . qq[ \
			LIMIT 1 \
		]);
		$sth->execute or log_warn($DBI::errstr, {-no_script_name => 1});
		
		return unless $sth->rows;

		# --------------------
		# open_until special case
		# --------------------
		if ($function =~ /^open_until/i) {
			my $tolerance = 1;
			$sth = $dbh->prepare(qq[SELECT id FROM command_queue \
				WHERE serial = ] . $dbh->quote($meter_serial) . qq[ \
				AND function = ] . $dbh->quote($function) . qq[ \
				AND param > ] . ($cleartext - $tolerance) . qq[ \
				AND param < ] . ($cleartext + $tolerance) . qq[ \
				LIMIT 1 \
			]);
			$sth->execute or log_warn($DBI::errstr, {-no_script_name => 1});

			if ($sth->rows) {
				my $row = $sth->fetchrow_hashref;
				$dbh->do(qq[DELETE FROM command_queue \
					WHERE id = ] . $row->{id} . qq[ \
				]) or log_warn($DBI::errstr, {-no_script_name => 1});			
				log_info("Deleted open_until command for $meter_serial, param: $cleartext", {-no_script_name => 1});
			} else {
				log_info("No matching open_until command found for $meter_serial, param: $cleartext", {-no_script_name => 1});
			}
			return;
		}

		# --------------------
		# status special case
		# --------------------
		if ($function =~ /^status$/i) {
			$dbh->do(qq[DELETE FROM command_queue \
				WHERE serial = ] . $dbh->quote($meter_serial) . qq[ \
				AND function = ] . $dbh->quote($function) . qq[ \
			]) or log_warn($DBI::errstr, {-no_script_name => 1});
			log_info("Deleted status command for $meter_serial", {-no_script_name => 1});
			return;
		}

		# --------------------
		# General case
		# --------------------
		$sth = $dbh->prepare(qq[SELECT id, has_callback FROM command_queue \
			WHERE serial = ] . $dbh->quote($meter_serial) . qq[ \
			AND function = ] . $dbh->quote($function) . qq[ \
			AND state = 'sent' \
		]);
		$sth->execute or log_warn($DBI::errstr, {-no_script_name => 1});

		if ($d = $sth->fetchrow_hashref) {
			if ($d->{has_callback}) {
				$dbh->do(qq[UPDATE command_queue SET \
					state = 'received', param = ] . $dbh->quote($cleartext) . qq[ \
					WHERE id = ] . $d->{id} . qq[ \
				]) or log_warn($DBI::errstr, {-no_script_name => 1});
				log_info("Marked serial $meter_serial, command $function for deletion", {-no_script_name => 1});
			} else {
				$dbh->do(qq[DELETE FROM command_queue \
					WHERE id = ] . $d->{id} . qq[ \
				]) or log_warn($DBI::errstr, {-no_script_name => 1});
				log_info("Deleted serial $meter_serial, command $function", {-no_script_name => 1});
			}
		}

	} else {
		log_warn("Serial $meter_serial checksum error", {-no_script_name => 1});
	}
}

# --------------------
# Connect to DB
# --------------------
if ($dbh = Nabovarme::Db->my_connect) {
	$dbh->{'mysql_auto_reconnect'} = 1;
	log_info("Connected to DB", {-no_script_name => 1});
} else {
	log_die("Can't connect to DB: $!", {-no_script_name => 1});
}

# --------------------
# Subscribe to topics
# --------------------
$subscribe_mqtt->subscribe(q[/cron/#], \&mqtt_handler);
$subscribe_mqtt->subscribe(q[/ping/#], \&mqtt_handler);
$subscribe_mqtt->subscribe(q[/version/#], \&mqtt_handler);
$subscribe_mqtt->subscribe(q[/status/#], \&mqtt_handler);
$subscribe_mqtt->subscribe(q[/open_until/#], \&mqtt_handler);
$subscribe_mqtt->subscribe(q[/open_until_delta/#], \&mqtt_handler);
$subscribe_mqtt->subscribe(q[/uptime/#], \&mqtt_handler);
$subscribe_mqtt->subscribe(q[/stack_trace/#], \&mqtt_handler);
$subscribe_mqtt->subscribe(q[/vdd/#], \&mqtt_handler);
$subscribe_mqtt->subscribe(q[/rssi/#], \&mqtt_handler);
$subscribe_mqtt->subscribe(q[/ssid/#], \&mqtt_handler);
$subscribe_mqtt->subscribe(q[/set_ssid/#], \&mqtt_handler);
$subscribe_mqtt->subscribe(q[/set_pwd/#], \&mqtt_handler);
$subscribe_mqtt->subscribe(q[/set_ssid_pwd/#], \&mqtt_handler);
$subscribe_mqtt->subscribe(q[/scan_result/#], \&mqtt_handler);
$subscribe_mqtt->subscribe(q[/wifi_status/#], \&mqtt_handler);
$subscribe_mqtt->subscribe(q[/ap_status/#], \&mqtt_handler);
$subscribe_mqtt->subscribe(q[/save/#], \&mqtt_handler);
$subscribe_mqtt->subscribe(q[/mem/#], \&mqtt_handler);
$subscribe_mqtt->subscribe(q[/reset_reason/#], \&mqtt_handler);
$subscribe_mqtt->subscribe(q[/flash_id/#], \&mqtt_handler);
$subscribe_mqtt->subscribe(q[/flash_size/#], \&mqtt_handler);
$subscribe_mqtt->subscribe(q[/network_quality/#], \&mqtt_handler);

$subscribe_mqtt->run();


1;

__END__
