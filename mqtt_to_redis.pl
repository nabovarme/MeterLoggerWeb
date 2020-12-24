#!/usr/bin/perl -w

use strict;
use Data::Dumper;
use Net::MQTT::Simple;
use DBI;
use Crypt::Mode::CBC;
use Digest::SHA qw( sha256 hmac_sha256 );
use Config::Simple;
use Redis;

use lib qw( /etc/apache2/perl );
use lib qw( /opt/local/apache2/perl/ );

use constant CONFIG_FILE => qw (/etc/Nabovarme.conf );

my $config = new Config::Simple(CONFIG_FILE) || die $!;

my $redis_host = $config->param('redis_host') || '127.0.0.1';
my $redis_port = $config->param('redis_port') || '6379';
my $redis = Redis->new(
	server => "$redis_host:$redis_port",
);

my $queue_name = 'mqtt';

warn("starting...\n");

my $protocol_version;
my $unix_time;
my $meter_serial;
my $sw_version;
my $valve_status;
my $uptime;
my $ssid;
my $rssi;
my $wifi_status;
my $ap_status;
my $reset_reason;

my $mqtt = Net::MQTT::Simple->new($config->param('mqtt_host'));

my $mqtt_data = undef;

# start mqtt run loop
$mqtt->run(	q[/sample/v2/#] => \&v2_mqtt_handler,
	q[/version/v2/#] => \&v2_mqtt_handler,
	q[/status/v2/#] => \&v2_mqtt_handler,
	q[/uptime/v2/#] => \&v2_mqtt_handler,
	q[/ssid/v2/#] => \&v2_mqtt_handler,
	q[/rssi/v2/#] => \&v2_mqtt_handler,
	q[/wifi_status/v2/#] => \&v2_mqtt_handler,
	q[/ap_status/v2/#] => \&v2_mqtt_handler,
	q[/reset_reason/v2/#] => \&v2_mqtt_handler,
	q[/scan_result/v2/#] => \&v2_mqtt_handler,
	q[/crypto/v2/#] => \&v2_mqtt_handler
);

# end of main


sub v2_mqtt_handler {
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
