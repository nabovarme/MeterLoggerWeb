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
	return sprintf("%04d-%02d-%02d %02d:%02d:%02d.%03d", 
		$year + 1900, $mon + 1, $mday, $hour, $min, $sec, int($microseconds / 1000));
}

# Ensure signal handler cleans up properly
$SIG{INT} = sub { log_info("Caught SIGINT, exiting.", {-no_script_name => 1}); exit 0; };

my $mqtt_host  = $ENV{'MQTT_HOST'}  or log_die("MQTT_HOST not set");
my $mqtt_port  = $ENV{'MQTT_PORT'}  or log_die("MQTT_PORT not set");
my $redis_host = $ENV{'REDIS_HOST'} or log_die("REDIS_HOST not set");
my $redis_port = $ENV{'REDIS_PORT'} or log_die("REDIS_PORT not set");

my $redis = Redis->new(server => "$redis_host:$redis_port", reconnect => 60);

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
	topic   => '#',
	callback => \&process_mqtt_message
);

sub process_mqtt_message {
	my ($topic, $message) = @_;
	return unless ($topic && defined $message);

	# Guard clause: ignore status/config topics entirely
	return if $topic =~ m!/config/! || $topic =~ m!/status!;

	my $recv_time = get_timestamp_ms();
	my $payload   = freeze({ topic => $topic, message => $message });

	# Strict, non-overlapping routing block
	if ($topic =~ m!/sample/v\d+/!) {
		log_info("DEBUG [mqtt_to_redis] [$recv_time] Pushing to telemetry queue -> $topic", {-no_script_name => 1});
		$redis->rpush('mqtt:queue:telemetry', $payload);
	}
	elsif ($topic =~ m!/syslog/!) {
		log_info("DEBUG [mqtt_to_redis] [$recv_time] Pushing to syslog queue -> $topic", {-no_script_name => 1});
		$redis->rpush('mqtt:queue:syslog', $payload);
	}
	elsif ($topic =~ m!/cmd_ack/!) {
		log_info("DEBUG [mqtt_to_redis] [$recv_time] Pushing to cmd_ack queue -> $topic", {-no_script_name => 1});
		$redis->rpush('mqtt:queue:cmd_ack', $payload);
	}
}

$cv->wait;
