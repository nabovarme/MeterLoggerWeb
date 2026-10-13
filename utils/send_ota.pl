#!/usr/bin/perl -w

use strict;
use warnings;
use Data::Dumper;
use Nabovarme::MQTT_RPC;

# Parse arguments
my $serial  = $ARGV[0] or die "Usage: $0 <serial> [version_dir]\nExample: $0 9999995\n         $0 9999995 20261013_152158\n";
my $version = $ARGV[1] // ""; # Default to empty string if not provided

# Define the firmware directory based on whether a version was provided
my $fw_dir = "/home/meterlogger/firmware/$serial";
$fw_dir .= "/$version" if $version ne "";

# Verify the release exists
if (!-d $fw_dir) {
	die "Error: Firmware directory not found: $fw_dir\n";
}

# Helper function to extract just the hash string from the output of sha256sum
sub get_hash {
	my $file = shift;
	open(my $fh, '<', $file) or die "Error: Cannot open $file: $!\nRun 'make release' or 'make custom_release' to generate checksum files.\n";
	my $line = <$fh>;
	close($fh);
	
	my ($hash) = split(/\s+/, $line);
	return $hash;
}

print "Reading checksums from $fw_dir...\n";
my $sha1 = get_hash("$fw_dir/user1.ota.bin.sha256");
my $sha2 = get_hash("$fw_dir/user2.ota.bin.sha256");

# Construct the exact OTA payload expected by the meter
my $payload = "version=$version&sha1=$sha1&sha2=$sha2";

print "Connecting to database...\n";
my $rpc = Nabovarme::MQTT_RPC->new();
if (!$rpc->connect()) {
	die "Failed to connect to database.\n";
}

print "Dispatching OTA Upgrade command for serial $serial...\n";
print "Payload: $payload\n";

# Queue the command with a 30-second timeout to await the meter's initial acknowledgment
my $success = $rpc->call({
	serial   => $serial,
	function => 'ota_upgrade',
	param    => $payload,
	stateful => 1,         # Stateful to prevent overwriting other pending non-OTA commands
	timeout  => 30,
	callback => sub {
		my $res = shift;
		print "\nMeter Acknowledged OTA Command:\n";
		print "Response: " . $res->{param} . "\n";
	}
});

if ($success) {
	print "\nSuccess: OTA upgrade initiated.\n";
} else {
	warn "\nTimeout: Command queued, but no immediate acknowledgment from meter within 30 seconds.\n";
}

1;
