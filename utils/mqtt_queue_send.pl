#!/usr/bin/perl -w

use strict;
use warnings;
use Data::Dumper;
use Getopt::Long qw(GetOptions);

use Nabovarme::MQTT_RPC;

my $is_stateful = 0;
my $timeout     = 0;
my $message     = '';
my $help        = 0;

my $usage = "Usage: $0 [-h|--help] [-s|--stateful] [-t|--timeout seconds] [-m|--message value] <function> <serial> [serial ...]\n";

if (!@ARGV) {
	print $usage;
	exit(0);
}

GetOptions(
	'help|h'      => \$help,
	'stateful|s!' => \$is_stateful,
	'timeout|t=i' => \$timeout,
	'message|m=s' => \$message,
) or die $usage;

if ($help) {
	print $usage;
	exit(0);
}

my $mqtt_cmd = shift @ARGV;

if (!$mqtt_cmd) {
	die $usage;
}

my @meter_serials = @ARGV;

if (!@meter_serials) {
	die "At least one meter serial is required\n$usage";
}

my $rpc = Nabovarme::MQTT_RPC->new();

if (!$rpc->connect()) {
	die "Failed to connect to database\n";
}

my $success_count = 0;

for my $meter_serial (@meter_serials) {
	print "Queueing command for meter $meter_serial";

	my $callback;

	if ($timeout > 0) {
		print " and waiting up to ${timeout}s for reply...\n";

		$callback = sub {
			my $res = shift;

			print "Received reply from meter $res->{serial}:\n";
			print "  Function:  $res->{function}\n";
			print "  Parameter: $res->{param}\n";
			print "  Received:  " . scalar(localtime($res->{unix_time})) . " (" . $res->{unix_time} . ")\n";
		};
	} else {
		print " (fire-and-forget)...\n";
	}

	my $success = $rpc->call({
		serial   => $meter_serial,
		function => $mqtt_cmd,
		param    => $message,
		stateful => $is_stateful,
		timeout  => $timeout,
		callback => $callback
	});

	if ($success) {
		print "Success for meter $meter_serial.\n";
		$success_count++;
	} else {
		warn "Command failed or timed out for meter $meter_serial after $timeout seconds.\n";
	}
}

printf "Completed: %d/%d commands successful.\n",
	$success_count, scalar @meter_serials;

if ($success_count == @meter_serials) {
	exit(0);
} else {
	exit(1);
}
