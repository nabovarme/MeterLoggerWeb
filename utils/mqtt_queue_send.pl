#!/usr/bin/perl -w

use strict;
use warnings;
use Data::Dumper;

# Assuming the module is in your standard include path
use Nabovarme::MQTT_RPC;

# Parse arguments
my $meter_serial = $ARGV[0] or die "Usage: $0 <serial> <function> [param] [is_stateful] [timeout]\n";
my $mqtt_cmd     = $ARGV[1] or die "Usage: $0 <serial> <function> [param] [is_stateful] [timeout]\n";
my $message      = $ARGV[2] // '';
my $is_stateful  = $ARGV[3] || 0;
my $timeout      = $ARGV[4] || 0;

my $rpc = Nabovarme::MQTT_RPC->new();

if (!$rpc->connect()) {
	die "Failed to connect to database\n";
}

# If a timeout is provided, we will pass a callback to make the script wait for the meter's reply
my $callback = undef;
if ($timeout > 0) {
	print "Queueing command and waiting up to ${timeout}s for reply from meter...\n";
	$callback = sub {
		my $res = shift;
		print "Received reply:\n";
		print Dumper({
			"meter serial" => $res->{serial},
			"function"     => $res->{function},
			"param"        => $res->{param},
			"unix_time"    => $res->{unix_time}
		});
	};
} else {
	print "Queueing command (fire-and-forget)...\n";
}

# Dispatch the command via the RPC module
my $success = $rpc->call({
	serial   => $meter_serial,
	function => $mqtt_cmd,
	param    => $message,
	stateful => $is_stateful,
	timeout  => $timeout,
	callback => $callback
});

# Evaluate the result
if ($success) {
	print "Success.\n";
} else {
	warn "Command timed out after $timeout seconds.\n";
}

1;
