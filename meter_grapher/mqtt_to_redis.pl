#!/usr/bin/perl -w

use strict;
use Data::Dumper;
use Net::MQTT::Simple;
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

my $redis = Redis->new(
	server => "$redis_host:$redis_port",
);

my $queue_name = 'mqtt';

warn("starting...\n");

my $mqtt = Net::MQTT::Simple->new("$mqtt_host:$mqtt_port");

my $mqtt_data = undef;

# start mqtt run loop
$mqtt->run(	q[/sample/v2/#] => \&mqtt_handler,
	q[/version/v2/#] => \&mqtt_handler,
	q[/status/v2/#] => \&mqtt_handler,
	q[/uptime/v2/#] => \&mqtt_handler,
	q[/ssid/v2/#] => \&mqtt_handler,
	q[/rssi/v2/#] => \&mqtt_handler,
	q[/wifi_status/v2/#] => \&mqtt_handler,
	q[/ap_status/v2/#] => \&mqtt_handler,
	q[/reset_reason/v2/#] => \&mqtt_handler,
	q[/scan_result/v2/#] => \&mqtt_handler,
	q[/offline/v1/#] => \&mqtt_handler,
	q[/chip_id/v2/#] => \&mqtt_handler,
	q[/flash_id/v2/#] => \&mqtt_handler,
	q[/flash_size/v2/#] => \&mqtt_handler,
	q[/flash_error/v2/#] => \&mqtt_handler,
	q[/reset_reason/v2/#] => \&mqtt_handler,
	q[/network_quality/v2/#] => \&mqtt_handler
);

# end of main


sub mqtt_handler {
	my ($topic, $message) = @_;

	# Create the next id
	my $id = $redis->incr(join(':',$queue_name, 'id'));
	my $job_id = join(':', $queue_name, $id);

	my %data = (topic => $topic, message => $message);

	# Set the data first
	$redis->hmset($job_id, %data);

	# Then add the job to the queue
	$redis->rpush(join(':', $queue_name, 'queue'), $job_id);
}


__END__
