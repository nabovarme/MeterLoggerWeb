#!/usr/bin/perl -w

use strict;
use warnings;
use Data::Dumper;
use Nabovarme::MQTT_RPC;

# Parse arguments
my $serial  = $ARGV[0] or die "Usage: $0 <serial> [version_dir]\nExample: $0 9999995\n         $0 9999995 20261013_152158\n";
my $version = $ARGV[1] // "latest"; # Default to the automated 'latest' symlink

my $fw_dir = "/home/meterlogger/firmware/$serial/$version";

# Fallback to root serial dir if 'latest' doesn't exist but root does
if (!-d $fw_dir &&$version eq "latest" && -d "/home/meterlogger/firmware/$serial") {
	$fw_dir = "/home/meterlogger/firmware/$serial";
	$version = "";
}

# Verify the release exists
if (!-d $fw_dir) {
	die "Error: Firmware directory not found: $fw_dir\n";
}

# Helper function to get the hash - calculates it dynamically if the .sha256 file is missing
sub get_hash {
	my $bin_file = shift;
	my $sha_file = "$bin_file.sha256";
	my $hash;

	if (!-f $bin_file) {
		die "Error: Firmware binary not found: $bin_file\n";
	}

	if (-f $sha_file) {
		open(my $fh, '<', $sha_file) or die "Error: Cannot open $sha_file: $!\n";
		my $line = <$fh>;
		close($fh);
		($hash) = split(/\s+/, $line);
	} else {
		# Calculate on the fly (perfect for automated builder pipelines)
		my $output = `sha256sum $bin_file`;
		($hash) = split(/\s+/, $output);
	}
	return $hash;
}

print "Reading/calculating checksums from $fw_dir...\n";
my $sha1 = get_hash("$fw_dir/user1.ota.bin");
my $sha2 = get_hash("$fw_dir/user2.ota.bin");

# Construct the exact OTA payload expected by the meter
my $payload = "version=$version&sha1=$sha1&sha2=$sha2";

print "Connecting to database...\n";
my $rpc = Nabovarme::MQTT_RPC->new();
if (!$rpc->connect()) {
	die "Failed to connect to database.\n";
}

print "Dispatching OTA Upgrade command for serial $serial...\n";
print '-' x 50 . "\n";

# 1. Queue command and stream progress
my $ota_error = 0;
my $success = $rpc->call({
	serial     => $serial,
	function   => 'ota_upgrade',
	param      => $payload,
	stateful   => 1,
	continuous => 1,          # Enable the new streaming feature!
	timeout    => 300,        # 5 minutes maximum for OTA flash
	callback   => sub {
		my $res = shift;
		my $msg = $res->{param};
		
		# Skip printing if the param is just our own payload bouncing back
		print "Meter: $msg\n" if $msg ne $payload;
		
		# Terminal Error states
		if ($msg =~ /error/i || $msg =~ /fail/i) {$ota_error = 1;
			return 0; # Return 0 to exit continuous mode and cleanup DB
		}
		
		# Terminal Success states
		if ($msg =~ /success/i || $msg =~ /staging/i || $msg =~ /complete/i || $msg =~ /100\%/ || $msg =~ /permanently/i) {
			return 0; # Return 0 to exit continuous mode and cleanup DB
		}
		
		return 1; # Continue listening
	}
});

print '-' x 50 . "\n";

if (!$success) {
	die "\nFailed: Command timed out or queue error occurred.\n";
}
if ($ota_error) {
	die "\nFailed: Meter aborted the OTA upgrade. See error above.\n";
}

print "\nFlashing complete. Waiting for meter to reboot into new ROM...\n";
sleep 15; # Give the ESP8266 time to reboot, init Wi-Fi, and connect to MQTT

# 2. Wait for the meter to come back online
my $online = 0;
for (my $i = 1; $i <= 15; $i++) {
	print "Pinging meter (Attempt $i / 15)...\n";
	
	my $ping_success = $rpc->call({
		serial   => $serial,
		function => 'version',
		param    => '',
		stateful => 0,
		timeout  => 10,
		callback => sub {
			my $res = shift;
			print "\n>>> METER IS BACK ONLINE <<<\n";
			print "Firmware Version Running: " . $res->{param} . "\n";
			$online = 1;
		}
	});
	
	last if $online;
	sleep 3;
}

if (!$online) {
	die "\nWarning: Meter did not come back online within the expected time. It may have failed to boot the new ROM and safely reverted to the old one.\n";
}

print "\nOTA Upgrade Pipeline Completed Successfully.\n";
1;
