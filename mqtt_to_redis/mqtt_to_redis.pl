#!/usr/bin/perl -w

use strict;
use warnings;
use AnyEvent;
use AnyEvent::MQTT;
use Redis;
use Storable qw(nfreeze);

use Nabovarme::Utils;

# --- Config from environment ---
my $mqtt_host = $ENV{'MQTT_HOST'}
	or log_die("ERROR: MQTT_HOST environment variable not set", {-no_script_name => 1});

my $mqtt_port = $ENV{'MQTT_PORT'}
	or log_die("ERROR: MQTT_PORT environment variable not set", {-no_script_name => 1});

my $redis_host = $ENV{'REDIS_HOST'}
	or log_die("ERROR: REDIS_HOST environment variable not set", {-no_script_name => 1});

my $redis_port = $ENV{'REDIS_PORT'}
	or log_die("ERROR: REDIS_PORT environment variable not set", {-no_script_name => 1});

# Establish Redis connection with auto-reconnect fallback
my $redis = Redis->new(
	server    => "$redis_host:$redis_port",
	reconnect => 60,
);

warn("starting MQTT to Redis Router...\n");

# Initialize the AnyEvent::MQTT client
# Setting clean_session to 0 tells the broker to buffer messages for us if we disconnect
my $mqtt = AnyEvent::MQTT->new(
	host          => $mqtt_host,
	port          => $mqtt_port,
	clean_session => 0,
	client_id     => "nabovarme_mqtt_bridge_" . $$,
);

# Subscribe to everything - we route it internally
$mqtt->subscribe(
	topic    => q[/#],
	qos      => 1,
	callback => \&mqtt_handler,
);

# Enter the AnyEvent main loop
AnyEvent->condvar->recv;

sub mqtt_handler {
	my ($topic, $message) = @_;

	# Safely isolate empty or malformed network packets on startup
	return unless defined $topic;
	$message = '' unless defined $message;

	# Pack the topic and binary ciphertext into a single self-contained serialized string
	my $payload = nfreeze({ topic => $topic, message => $message });

	eval {
		my @queues;

		# 1. Route to Telemetry Worker
		# Handles: /sample/
		if ($topic =~ m!/sample/!) {
			push @queues, 'mqtt:queue:telemetry';
		}
		
		# 2. Route to Syslog / Status Worker
		# Handles: /version/, /uptime/, /vdd/, /rssi/, /ssid/, /wifi_status/, /ap_status/,
		#          /chip_id/, /flash_id/, /flash_size/, /reset_reason/, /network_quality/, 
		#          /offline/, /flash_error/, /cnx_csa_fn_called/, /status/, /set_ap_mesh_pwd/,
		#          /mem/, /scan_result/
		if ($topic =~ m!/(?:version|uptime|vdd|rssi|ssid|wifi_status|ap_status|chip_id|flash_id|flash_size|reset_reason|network_quality|offline|flash_error|cnx_csa_fn_called|status|set_ap_mesh_pwd|mem|scan_result)/!) {
			push @queues, 'mqtt:queue:syslog';
		}

		# 3. Route to Command ACK Worker (Special Cases)
		# These are specifically the ACK replies from commands triggered by the backend
		# Handles: /status/, /open_until/, /open_until_delta/, /scan_result/, /test_ssid_pwd_result/,
		#          /stack_trace_result/, /ota_update/, /ota_upgrade/
		if ($topic =~ m!/(?:status|open_until|open_until_delta|scan_result|test_ssid_pwd_result|stack_trace_result|ota_up(?:date|grade))/!) {
			push @queues, 'mqtt:queue:cmd_ack';
		}

		# 4. Route to Command ACK Worker (Generic ACKs)
		# Handles: /ping/, /open/, /close/, /set_cron/, /clear_cron/, /cron/, /set_ssid/, /set_pwd/, 
		#          /set_ssid_pwd/, /test_ssid_pwd/, /start_ap/, /stop_ap/, /start_fallback_ap/, 
		#          /fallback_status/, /reconnect/, /save/, /mem/, /restart/, /stack_trace/, /set_key/
		if (!@queues && $topic =~ m!/v\d+/[^/]+/\d+$!) {
			push @queues, 'mqtt:queue:cmd_ack';
		}

		# Fan-out push to Redis
		foreach my $q (@queues) {
			$redis->rpush($q, $payload);
		}
	};
	if ($@) {
		warn("Error pushing MQTT data to Redis: $@\n");
	}
}
