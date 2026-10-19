#!/usr/bin/perl

use strict;
use warnings;

use AnyEvent::MQTT;
use Redis;
use Storable qw(freeze);
use Time::HiRes qw(gettimeofday);

use Nabovarme::Utils;

# MQTT topic lists

# 1. State & Attributes: Topics that update columns in the `meters` database table via worker_meters.pl
my @meter_topics = qw(
	version uptime ssid rssi wifi_status ap_status network_quality
	disconnect_count status open close chip_id flash_id flash_size reset_reason
);

# 2. Triggered Command Responses: State responses that must ALSO clear matching rows in `command_queue` via worker_cmd_ack.pl
my @cmd_ack_topics = qw(
	open close status version uptime ssid rssi wifi_status ap_status
	chip_id flash_id flash_size reset_reason disconnect_count
);

# 3. System & Audit Events: Asynchronous events inserted into the `log` or `wifi_scan` tables via worker_events.pl
my @event_topics = qw(
	offline flash_error cnx_csa_fn_called vdd mem scan_result
);

# 4. Standard RPC Commands: Known command endpoints used by the catch-all router to suppress "Unknown command" warnings
my @known_command_topics = qw(
	ping open_until open_until_delta set_cron cron clear_cron
	stack_trace stack_trace_result read_stack_trace
	set_ssid set_pwd set_ssid_pwd test_ssid_pwd test_ssid_pwd_result
	set_ap_mesh_pwd start_ap stop_ap start_fallback_ap fallback_status reconnect
	save restart set_key set_mqtt_host scan ota_update ota_upgrade
	reset_reason disconnect_count
);

# Compile MQTT topic patterns
my $config_topic_re = qr{^/config/};
my $sample_topic_re = qr{^/sample/v\d+/};

my $meter_topic_re = qr{^/(?:@{[join '|', @meter_topics]})/};
my $cmd_ack_topic_re = qr{/(?:@{[join '|', @cmd_ack_topics]})};
my $event_topic_re = qr{^/(?:@{[join '|', @event_topics]})/};
my $known_command_topic_re = qr{^/(?:@{[join '|', @known_command_topics]})/};

$SIG{INT} = sub {
	log_info("Caught SIGINT, exiting.", {-no_script_name => 1});
	exit 0;
};

my $mqtt_host = $ENV{MQTT_HOST}
	or log_die("MQTT_HOST not set");
my $mqtt_port = $ENV{MQTT_PORT}
	or log_die("MQTT_PORT not set");
my $redis_host = $ENV{REDIS_HOST}
	or log_die("REDIS_HOST not set");
my $redis_port = $ENV{REDIS_PORT}
	or log_die("REDIS_PORT not set");

my $redis = Redis->new(
	server => "$redis_host:$redis_port",
	reconnect => 60,
);

log_info("Starting MQTT to Redis Router (PID $$)...", {-no_script_name => 1});

my $cv = AnyEvent->condvar;

my $mqtt = AnyEvent::MQTT->new(
	host => $mqtt_host,
	port => $mqtt_port,
	on_error => sub {
		my ($fatal, $message) = @_;

		log_warn("MQTT Error: $message", {-no_script_name => 1});
		$cv->send if $fatal;
	}
);

my $guard = $mqtt->subscribe(
	topic => '#',
	callback => \&process_mqtt_message,
);

sub get_timestamp_ms {
	my ($seconds, $microseconds) = gettimeofday();
	my ($sec, $min, $hour, $mday, $mon, $year) = localtime($seconds);

	return sprintf(
		"%04d-%02d-%02d %02d:%02d:%02d.%03d",
		$year + 1900,
		$mon + 1,
		$mday,
		$hour,
		$min,
		$sec,
		int($microseconds / 1000),
	);
}

sub process_mqtt_message {
	my ($topic, $message) = @_;

	return unless $topic && defined $message;
	return if $topic =~ $config_topic_re; # Ignore outbound commands from broker

	my $payload = freeze({ topic => $topic, message => $message });

	# 1. High-Frequency Measurement Telemetry
	if ($topic =~ $sample_topic_re) {
		$redis->rpush('mqtt:queue:telemetry', $payload);
	}

	# 2. State & Meter Attributes (Updates `meters` table)
	elsif ($topic =~ $meter_topic_re) {
		$redis->rpush('mqtt:queue:meters', $payload);

		# Forward to cmd_ack if this response was triggered by an RPC command
		$redis->rpush('mqtt:queue:cmd_ack', $payload)
			if $topic =~ $cmd_ack_topic_re;
	}

	# 3. System Events & Audit Logging (Inserts into `log` / `wifi_scan`)
	elsif ($topic =~ $event_topic_re) {
		$redis->rpush('mqtt:queue:events', $payload);
	}

	# 4. Command ACKs & Unknown Command Catch-All (Clears `command_queue`)
	else {
		# Catch-all handles ping, open_until, set_cron, ota_update, test_ssid_pwd_result,
		# as well as unknown command NACKs (e.g., error=unknown_command)
		$redis->rpush('mqtt:queue:cmd_ack', $payload);

		# Route unknown/unrecognized commands to events queue as well for logging
		if ($topic !~ $known_command_topic_re) {
			log_warn(
				"Routing unknown command response to events and cmd_ack: $topic",
				{-no_script_name => 1}
			);
			$redis->rpush('mqtt:queue:events', $payload);
		}
	}
}

$cv->wait;
