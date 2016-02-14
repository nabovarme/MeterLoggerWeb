#! /opt/local/bin/perl -w

use strict;
use Data::Dumper;
use Net::MQTT::Simple;
use Storable;

use constant STORABLE_FILE => 'mqtt_queue.storable';

$SIG{INT} = \&sig_int_handler;

my $mqtt;
if (-e STORABLE_FILE) {
	warn "loaded from file";
	$mqtt = retrieve(STORABLE_FILE);
	warn Dumper $mqtt;
}
else {
	warn "new mqtt";
	$mqtt = Net::MQTT::Simple->new("loppen.christiania.org");
	warn Dumper $mqtt;
}

$mqtt->publish("/topic/here" => "foo");
warn Dumper $mqtt;

$mqtt->run();


sub sig_int_handler {
	store $mqtt, STORABLE_FILE;
	exit 1;
}