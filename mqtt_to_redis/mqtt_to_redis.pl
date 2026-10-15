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

	# Pack the topic and binary ciphertext into a single serialized payload
	my $payload = nfreeze({ topic => $topic, message => $message });

	eval {
		my @queues;

		# 1. Telemetry Queue (Strictly sample topics)
		if ($topic =~ m!^/sample/!) {
			push @queues, 'mqtt:queue:telemetry';
		}
		# 2. Command ACK Queue (Strictly command response & ACK topics)
		elsif ($topic =~ m!^/(?:ping|open|open_until|open_until_delta|close|set_cron|cron|clear_cron|stack_trace_result|read_stack_trace|set_ssid|set_pwd|set_ssid_pwd|test_ssid_pwd|test_ssid_pwd_result|start_ap|stop_ap|start_fallback_ap|fallback_status|reconnect|save|restart|set_key|scan_result|ota_update|ota_upgrade)(?:/|$)!) {
			push @queues, 'mqtt:queue:cmd_ack';
		}
		# 3. Syslog Queue (Device state & telemetry health metrics)
		elsif ($topic =~ m!^/(?:version|status|uptime|vdd|rssi|ssid|wifi_status|ap_status|set_ap_mesh_pwd|chip_id|flash_id|flash_size|reset_reason|network_quality|offline|flash_error|cnx_csa_fn_called|mem)(?:/|$)!) {
			push @queues, 'mqtt:queue:syslog';
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
