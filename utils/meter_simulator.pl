#!/usr/bin/perl -w

use strict;
use warnings;
use Time::HiRes qw(time);
use Digest::SHA qw(sha256 hmac_sha256);
use Crypt::Mode::CBC;
use Math::Random::Secure qw(rand);
use AnyEvent;
use AnyEvent::MQTT;

use Nabovarme::Db;

my $serial = $ARGV[0] or die "Usage: $0 <serial>\n";

$| = 1; # Autoflush STDOUT

# --- Connect to DB to fetch the AES Key ---
my $dbh = Nabovarme::Db->my_connect or die "Database connection failed\n";
my $sth = $dbh->prepare("SELECT `key` FROM meters WHERE serial = ? LIMIT 1");
$sth->execute($serial);

my $row = $sth->fetchrow_hashref or die "Serial '$serial' not found in database.\n";
my $hex_key = $row->{key} or die "No encryption key found for meter '$serial'.\n";
$dbh->disconnect;

# --- Setup Crypto ---
my $sha256   = sha256(pack('H*', $hex_key));
my $aes_key  = substr($sha256, 0, 16);
my $hmac_key = substr($sha256, 16, 16);
my $cbc      = Crypt::Mode::CBC->new('AES');

# --- Connect to MQTT ---
my $mqtt_host = $ENV{MQTT_HOST} || 'mqtt';
my $mqtt_port = $ENV{MQTT_PORT} || 1883;

print "Starting Advanced Meter Simulator for $serial...\n";
print "Connecting to MQTT at $mqtt_host:$mqtt_port\n";

my $mqtt = AnyEvent::MQTT->new(
	host          => $mqtt_host,
	port          => $mqtt_port,
	clean_session => 0,
	client_id     => "meter_sim_${serial}_" . int(rand(10000))
);

my $cv = AnyEvent->condvar;

# Maintain fake state
my $current_valve_status = "open";

# --- Subscribe to incoming commands (/config/v2/...) ---
my $config_topic = "/config/v2/$serial/#";
$mqtt->subscribe(
	topic    => $config_topic,
	qos      => 1,
	callback => sub {
		my ($topic, $message) = @_;
		return unless length($message) >= 48;

		my $mac        = substr($message, 0, 32);
		my $iv         = substr($message, 32, 16);
		my $ciphertext = substr($message, 48);

		# Extract function from topic (/config/v2/serial/timestamp/function)
		my ($function) = $topic =~ m!/config/v2/[^/]+/\d+/([^/]+)!;
		return unless $function;

		# Authenticate and Decrypt
		if ($mac eq hmac_sha256($topic . $iv . $ciphertext, $hmac_key)) {
			my $cleartext = $cbc->decrypt($ciphertext, $aes_key, $iv);
			$cleartext =~ s/[\x00\s]+$//; # Strip padding/nulls
			print "[RECEIVED COMMAND] Function: $function | Payload:$cleartext\n";

			my $now = int(time());

			# --- Dispatch dynamic replies based on the requested command ---
			if ($function eq 'status' || $function eq 'open' || $function eq 'close') {
				if ($function eq 'open')  { $current_valve_status = 'open'; }
				if ($function eq 'close') { $current_valve_status = 'close'; }
				send_encrypted_payload("/status/v2/$serial/$now", $current_valve_status);
			}
			elsif ($function eq 'version') {
				send_encrypted_payload("/version/v2/$serial/$now", "simulator-1.0.0");
			}
			elsif ($function eq 'ping') {
				send_encrypted_payload("/ping/v2/$serial/$now", "ping");
			}
			elsif ($function eq 'scan') {
				# Send a few fake networks
				send_encrypted_payload("/scan_result/v2/$serial/$now", "ssid=MeterLoggerMesh&bssid=00:11:22:33:44:55&rssi=-45&channel=1&auth_mode=3&pairwise_cipher=1&group_cipher=1&phy_11b=0&phy_11g=1&phy_11n=1&wps=0");
				send_encrypted_payload("/scan_result/v2/$serial/$now", "ssid=GuestWiFi&bssid=AA:BB:CC:DD:EE:FF&rssi=-80&channel=6&auth_mode=3&pairwise_cipher=1&group_cipher=1&phy_11b=0&phy_11g=1&phy_11n=1&wps=0");
				# End of scan list (empty payload) required by worker_cmd_ack to release the command
				send_encrypted_payload("/scan_result/v2/$serial/$now", "");
			}
			elsif ($function eq 'network_quality') {
				send_encrypted_payload("/network_quality/v2/$serial/$now", "ping_response_time=12&ping_average_packet_loss=0%&disconnect_count=0");
			}
			elsif ($function eq 'vdd') {
				send_encrypted_payload("/vdd/v2/$serial/$now", "3.31");
			}
			elsif ($function eq 'rssi') {
				send_encrypted_payload("/rssi/v2/$serial/$now", "-45");
			}
			elsif ($function eq 'ssid') {
				send_encrypted_payload("/ssid/v2/$serial/$now", "MeterLoggerMesh");
			}
			elsif ($function eq 'wifi_status') {
				send_encrypted_payload("/wifi_status/v2/$serial/$now", "5"); # 5 = STATION_GOT_IP
			}
			elsif ($function eq 'ap_status') {
				send_encrypted_payload("/ap_status/v2/$serial/$now", "0");
			}
			elsif ($function eq 'chip_id' || $function eq 'flash_id') {
				send_encrypted_payload("/$function/v2/$serial/$now", "0xDEADBEEF");
			}
			elsif ($function eq 'flash_size') {
				send_encrypted_payload("/flash_size/v2/$serial/$now", "4194304");
			}
			elsif ($function eq 'reset_reason') {
				send_encrypted_payload("/reset_reason/v2/$serial/$now", "Simulator Boot");
			}
			elsif ($function eq 'mem') {
				send_encrypted_payload("/mem/v2/$serial/$now", "42000");
			}
			elsif ($function eq 'stack_trace') {
				send_encrypted_payload("/stack_trace_result/v2/$serial/$now", "No crash detected. Simulator is running flawlessly.");
			}
			elsif ($function eq 'test_ssid_pwd') {
				send_encrypted_payload("/test_ssid_pwd_result/v2/$serial/$now", "status=ok&rssi=-45");
			}
			elsif ($function eq 'ota_update' || $function eq 'ota_upgrade') {
				send_encrypted_payload("/$function/v2/$serial/$now", "success");
			}
			else {
				# Generic ACK for set_cron, clear_cron, save, restart, set_key, set_ssid_pwd, etc.
				send_encrypted_payload("/$function/v2/$serial/$now", "ok");
			}
		}
		else {
			print "[HMAC ERROR] Invalid signature on topic: $topic\n";
		}
	}
);

# --- Publish fake telemetry every 60 seconds (1 minute) ---
my $accumulated_volume = 1000.00;
my $accumulated_energy = 500.00;

my $sample_timer;
$sample_timer = AnyEvent->timer(
	after    => 1,
	interval => 60,
	cb       => sub {
		my $unix_time = int(time());
		my $topic = "/sample/v2/$serial/$unix_time";

		# Generate realistic fluctuating values
		my $t1     = 65.0 + (rand(4) - 2);
		my $t2     = 35.0 + (rand(2) - 1);
		my $tdif   = $t1 - $t2;
		my $flow   = ($current_valve_status eq 'open') ? 120 + int(rand(30)) : 0;
		my $effect = sprintf("%.2f", ($flow * $tdif * 4.184) / 3600);

		# Increment accumulators
		$accumulated_volume += ($flow / 60);
		$accumulated_energy += ($effect / 60);

		my $cleartext = sprintf(
			"t1=%.2f&t2=%.2f&tdif=%.2f&flow1=%d&effect1=%s&hr=1000&v1=%.2f&e1=%.2f&heap=42000",
			$t1, $t2, $tdif, $flow, $effect, $accumulated_volume, $accumulated_energy
		);

		send_encrypted_payload($topic, $cleartext);
		print "[SENT TELEMETRY] Topic: $topic | Payload:$cleartext\n";
	}
);

# --- Publish health/status messages every 600 seconds (10 minutes) ---
my $uptime_counter = 0;

my $status_timer;
$status_timer = AnyEvent->timer(
	after    => 5,
	interval => 600,
	cb       => sub {
		my $now = int(time());
		$uptime_counter += 600;

		send_encrypted_payload("/status/v2/$serial/$now", $current_valve_status);
		send_encrypted_payload("/network_quality/v2/$serial/$now", "ping_response_time=12&ping_average_packet_loss=0%&disconnect_count=0");
		send_encrypted_payload("/vdd/v2/$serial/$now", "3.31");
		send_encrypted_payload("/rssi/v2/$serial/$now", "-45");
		send_encrypted_payload("/uptime/v2/$serial/$now", $uptime_counter);

		print "[SENT STATUS BATCH] Periodic status updates dispatched.\n";
	}
);

print "Simulator running. Press Ctrl+C to exit.\n";
$cv->recv;

# Helper to construct and send the encrypted binary packet
sub send_encrypted_payload {
	my ($target_topic, $plaintext) = @_;

	my $iv         = join('', map(chr(int rand(256)), 1..16));
	my $padded     = $plaintext . "\0";
	my $ciphertext = $cbc->encrypt($padded, $aes_key, $iv);
	my $mac        = hmac_sha256($target_topic . $iv . $ciphertext, $hmac_key);

	my $payload = $mac . $iv . $ciphertext;

	$mqtt->publish(
		topic   => $target_topic,
		message => $payload,
		qos     => 0
	);
}

print "Simulator running. Press Ctrl+C to exit.\n";
$cv->recv;

