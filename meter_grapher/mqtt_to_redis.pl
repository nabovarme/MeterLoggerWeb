#!/usr/bin/perl -w

use strict;
use Data::Dumper;
use AnyEvent;
use AnyEvent::MQTT;
use DBI;
use Crypt::Mode::CBC;
use Digest::SHA qw( sha256 hmac_sha256 );
use Redis;

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

my $queue_name = 'mqtt';

warn("starting...\n");

# Initialize the AnyEvent::MQTT client
# Setting clean_session to 0 tells the broker to buffer messages for us if we disconnect
my $mqtt = AnyEvent::MQTT->new(
	host          => $mqtt_host,
	port          => $mqtt_port,
	clean_session => 0,
	client_id     => "nabovarme_mqtt_bridge_" . $$,
);

my $mqtt_data = undef;

# Define all topics to subscribe to (QoS 1 guarantees 'At Least Once' delivery)
my @topics = (
	q[/sample/v2/#],
	q[/version/v2/#],
	q[/status/v2/#],
	q[/uptime/v2/#],
	q[/ssid/v2/#],
	q[/rssi/v2/#],
	q[/wifi_status/v2/#],
	q[/ap_status/v2/#],
	q[/set_ap_mesh_pwd/v2/#],
	q[/reset_reason/v2/#],
	q[/scan_result/v2/#],
	q[/offline/v1/#],
	q[/chip_id/v2/#],
	q[/flash_id/v2/#],
	q[/flash_size/v2/#],
	q[/flash_error/v2/#],
	q[/network_quality/v2/#]
);

# Register subscriptions inside the asynchronous event loop
foreach my $topic_filter (@topics) {
	$mqtt->subscribe(
		topic    => $topic_filter,
		qos      => 1,
		callback => \&mqtt_handler,
	);
}

# Enter the AnyEvent main loop (this keeps the script running asynchronously)
AnyEvent->condvar->recv;

# end of main


sub mqtt_handler {
	my ($topic, $message) = @_;

	# Safely isolate empty or malformed network packets on startup
	return unless defined $topic;
	$message = '' unless defined $message;

	# Protect against Redis downtime or errors using eval
	eval {
		# 1. Fetch the next sequential ID (instantly flushed, no pipelining delays)
		my $id = $redis->incr(join(':', $queue_name, 'id'));
		
		if ($id) {
			my $job_id = join(':', $queue_name, $id);
			my %data = (topic => $topic, message => $message);

			# 2. Store payload hash
			$redis->hmset($job_id, %data);

			# 3. Push job reference to the processing queue for the DB worker
			$redis->rpush(join(':', $queue_name, 'queue'), $job_id);
		}
	};
	if ($@) {
		warn("Error pushing MQTT data to Redis: $@\n");
	}
}

__END__
