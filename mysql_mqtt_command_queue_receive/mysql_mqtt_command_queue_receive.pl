#!/usr/bin/perl -w

use strict;
use warnings;
use Data::Dumper;
use Net::MQTT::Simple;
use DBI;
use Crypt::Mode::CBC;
use Digest::SHA qw( sha256 hmac_sha256 );
use Config::Simple;
use Time::HiRes qw( gettimeofday usleep );

use lib qw( /etc/apache2/perl );
use Nabovarme::Db;

# --- Constants ---
use constant CONFIG_FILE          => '/etc/Nabovarme.conf';
use constant CACHE_DEFAULT_SEC    => 3600;    # default 1 hour for key cache
use constant PROCESS_DELAY_USEC   => 20_000;  # optional small delay between processing messages (20 ms)

# --- Config ---
my $config = new Config::Simple(CONFIG_FILE)
	or die Config::Simple->error();
my $mqtt_host = $config->param('mqtt_host');
my $mqtt_port = $config->param('mqtt_port');

my $config_cached_time = $config->param('cached_time') || CACHE_DEFAULT_SEC;

$SIG{INT} = \&sig_int_handler;

my ($dbh, $sth, $d);
my $key_cache = {};

my $subscribe_mqtt = Net::MQTT::Simple->new("$mqtt_host:$mqtt_port");

sub sig_int_handler {
	$subscribe_mqtt->disconnect();
	die "Interrupted\n";
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
	$sth = $dbh->prepare(qq[SELECT serial FROM command_queue WHERE serial = ? LIMIT 1]);
	$sth->execute($meter_serial);
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
		$sth = $dbh->prepare(qq[SELECT `key` FROM meters WHERE serial = ? LIMIT 1]);
		$sth->execute($meter_serial);
		if ($sth->rows) {
			$d = $sth->fetchrow_hashref;
			$key_cache->{$meter_serial}->{key} = $d->{key};
			$key_cache->{$meter_serial}->{cached_time} = time();
			$key = $d->{key} || warn "No AES key found\n";
		}
	}

	return unless $key;

	# --------------------
	# scan_result special case
	# --------------------
	if ($function =~ /^scan_result$/i) {
		print("Received MQTT reply from $meter_serial: $function, deleting from MySQL queue\n");
		$dbh->do(qq[DELETE FROM command_queue WHERE serial = ? AND function = 'scan'], undef, $meter_serial)
			or warn $DBI::errstr;
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
		$sth = $dbh->prepare(qq[SELECT serial FROM command_queue WHERE serial = ? AND function = ? LIMIT 1]);
		$sth->execute($meter_serial, $function) or warn $DBI::errstr;
		return unless $sth->rows;

		# --------------------
		# open_until special case
		# --------------------
		if ($function =~ /^open_until/i) {
			my $tolerance = 1;
			$sth = $dbh->prepare(qq[
				SELECT id FROM command_queue
				WHERE serial = ? AND function = ?
				AND param > ? AND param < ?
				LIMIT 1
			]);
			$sth->execute($meter_serial, $function, $cleartext - $tolerance, $cleartext + $tolerance)
				or warn $DBI::errstr;

			if ($sth->rows) {
				my $row = $sth->fetchrow_hashref;
				$dbh->do(qq[DELETE FROM command_queue WHERE id = ?], undef, $row->{id}) or warn $DBI::errstr;
				print("Deleted open_until command for $meter_serial, param: $cleartext");
			} else {
				print("No matching open_until command found for $meter_serial, param: $cleartext");
			}
			usleep(PROCESS_DELAY_USEC);
			return;
		}

		# --------------------
		# status special case
		# --------------------
		if ($function =~ /^status$/i) {
			$dbh->do(qq[DELETE FROM command_queue WHERE serial = ? AND function = ?], undef, $meter_serial, $function)
				or warn $DBI::errstr;
			print("Deleted status command for $meter_serial");
			usleep(PROCESS_DELAY_USEC);
			return;
		}

		# --------------------
		# General case
		# --------------------
		$sth = $dbh->prepare(qq[
			SELECT id, has_callback FROM command_queue
			WHERE serial = ? AND function = ? AND state = 'sent'
		]);
		$sth->execute($meter_serial, $function) or warn $DBI::errstr;

		if ($d = $sth->fetchrow_hashref) {
			if ($d->{has_callback}) {
				print("Marking serial $meter_serial, command $function for deletion\n");
				$dbh->do(qq[UPDATE command_queue SET state = 'received', param = ? WHERE id = ?], undef, $cleartext, $d->{id})
					or warn $DBI::errstr;
			} else {
				print("Deleting serial $meter_serial, command $function from MySQL queue\n");
				$dbh->do(qq[DELETE FROM command_queue WHERE id = ?], undef, $d->{id}) or warn $DBI::errstr;
			}
		}
		usleep(PROCESS_DELAY_USEC);

	} else {
		print("Serial $meter_serial checksum error\n");  
		usleep(PROCESS_DELAY_USEC);
	}
}

# --------------------
# Connect to DB
# --------------------
if ($dbh = Nabovarme::Db->my_connect) {
	$dbh->{'mysql_auto_reconnect'} = 1;
} else {
	warn "Can't connect to DB: $!";
	die $!;
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

# --- debug print helper ---
sub debug_print {
	my ($msg) = @_;
	print STDERR "$msg\n" if ($ENV{ENABLE_DEBUG} || '') =~ /^(1|true)$/i;
}

1;

__END__
