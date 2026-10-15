#!/usr/bin/perl -w

use strict;
use warnings;
use AnyEvent::MQTT;
use Redis;
use Storable qw(freeze);
use Time::HiRes qw(gettimeofday);

use Nabovarme::Utils;

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

# Ensure signal handler cleans up properly
$SIG{INT} = sub {
	log_info("Caught SIGINT, exiting.", {-no_script_name => 1});
	exit 0;
};

my $mqtt_host = $ENV{'MQTT_HOST'}
	or log_die("MQTT_HOST not set");
my $mqtt_port = $ENV{'MQTT_PORT'}
	or log_die("MQTT_PORT not set");
my $redis_host = $ENV{'REDIS_HOST'}
	or log_die("REDIS_HOST not set");
my $redis_port = $ENV{'REDIS_PORT'}
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

# Catch all published topics and process via explicit callback
my $guard = $mqtt->subscribe(
	topic => '#',
	callback => \&process_mqtt_message,
);

sub process_mqtt_message {
	my ($topic, $message) = @_;

	return unless ($topic && defined $message);

	# Ignore config publishes from the broker/dispatcher
	return if $topic =~ m!^/config/!;

	my $recv_time = get_timestamp_ms();
	my $payload = freeze({
		topic => $topic,
		message => $message,
	});

	if ($topic =~ m!^/sample/v\d+/!) {
		$redis->rpush('mqtt:queue:telemetry', $payload);
	}
	elsif ($topic =~ m!^/(?:ping|open|open_until|open_until_delta|close|set_cron|cron|clear_cron|stack_trace_result|read_stack_trace|set_ssid|set_pwd|set_ssid_pwd|test_ssid_pwd|test_ssid_pwd_result|start_ap|stop_ap|start_fallback_ap|fallback_status|reconnect|save|restart|set_key|scan_result|ota_update|ota_upgrade)/!) {
		# Strictly command ACKs
		log_debug(
			"[$recv_time] -> cmd_ack queue: $topic",
			{-no_script_name => 1},
		);

		$redis->rpush('mqtt:queue:cmd_ack', $payload);
	}
	elsif ($topic =~ m!^/(?:version|status|uptime|vdd|rssi|ssid|wifi_status|ap_status|set_ap_mesh_pwd|chip_id|flash_id|flash_size|reset_reason|network_quality|offline|flash_error|cnx_csa_fn_called|mem)/!) {
		# Shared: Acts as both a syslog metric AND a command response
		log_debug(
			"[$recv_time] -> syslog & cmd_ack queue: $topic",
			{-no_script_name => 1},
		);

		$redis->rpush('mqtt:queue:syslog', $payload);
		$redis->rpush('mqtt:queue:cmd_ack', $payload);
	}
	else {
		log_warn(
			"Unhandled/Dropped topic: $topic",
			{-no_script_name => 1},
		);
	}
}

$cv->wait;
