#!/usr/bin/perl -w

use strict;
use warnings;
use Data::Dumper;
use Nabovarme::MQTT_RPC;

# Ensure stdout flushes immediately
$| = 1;

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

# --- New Helper: Robust Retry Wrapper ---
sub send_command_with_retry {
	my ($function, $param, $timeout, $max_retries, $stateful) = @_;
	$timeout //= 5;
	$max_retries //= 3;
	$stateful //= 1;
	
	for (my $try = 1; $try <= $max_retries; $try++) {
		my $responded = 0;
		my $res_param = '';
		
		# Clear old queued commands of this type to ensure a clean slate
		$rpc->{dbh}->do("DELETE FROM command_queue WHERE serial = ? AND function = ?", undef, $serial, $function);
		$rpc->call({
			serial   => $serial,
			function => $function,
			param    => $param,
			stateful => $stateful,
			timeout  => $timeout,
			callback => sub {
				my $res = shift;
				$res_param = $res->{param};
				$responded = 1;
			}
		});
		
		return (1, $res_param) if $responded;
		print "  No response. Retrying '$function' ($try/$max_retries)...\n" if $try <$max_retries;
	}
	return (0, '');
}

# Subroutine to wait for meter to reboot and come online
sub wait_for_meter {
	my $delay = shift || 15;
	print "\nWaiting for meter to download firmware, flash, and reboot ($delay seconds)...\n";
	sleep $delay;

	print "Pinging meter to verify it comes back online (Retrying up to 30 times)...\n";
	# Use the robust retry helper to ping the meter (30 retries, 4s timeout each = ~2 mins of waiting)
	my ($ok, $res) = send_command_with_retry('version', '', 4, 30, 0);
	
	if ($ok) {
		print "\n>>> METER IS BACK ONLINE <<<\n";
		print "Firmware Version Running: $res\n";
		return 1;
	}
	return 0;
}

# Subroutine to execute the OTA command attempt
sub execute_ota {
	print "Dispatching OTA Upgrade command for serial $serial...\n";
	print '-' x 50 . "\n";

	my $ota_error = 0;
	my $unconfirmed_rom = 0;

	# Clear any old OTA commands before starting
	$rpc->{dbh}->do("DELETE FROM command_queue WHERE serial = ? AND function = 'ota_upgrade'", undef, $serial);

	my $success = $rpc->call({
		serial     => $serial,
		function   => 'ota_upgrade',
		param      => $payload,
		stateful   => 1,
		continuous => 1,
		timeout    => 300, # 5 minutes max
		callback   => sub {
			my $res = shift;
			my $msg = $res->{param};
			
			print "Meter: $msg\n" if $msg ne $payload;
			
			if ($msg =~ /error_unconfirmed_temp_rom/i) {$unconfirmed_rom = 1;
				$ota_error = 1;
				return 0; # Exit continuous mode
			}
			elsif ($msg =~ /error/i || $msg =~ /fail/i) {$ota_error = 1;
				return 0; # Exit continuous mode
			}
			
			# Exit on 'started' because the async MQTT flashing updates do NOT update the database queue
			if ($msg =~ /started/i || $msg =~ /success/i || $msg =~ /staging/i || $msg =~ /complete/i || $msg =~ /100\%/ || $msg =~ /permanently/i || $msg =~ /pending_confirmation/i || $msg =~ /restarting/i) {
				print "\n[+] Meter accepted OTA payload and is flashing in the background.\n";
				return 0; # Exit continuous mode
			}
			
			return 1;
		}
	});

	print '-' x 50 . "\n";

	return ($success, $ota_error, $unconfirmed_rom);
}

# Initial execution
my ($success, $ota_error, $unconfirmed_rom) = execute_ota();

# Check if we tripped the unconfirmed temp ROM condition
if ($ota_error &&$unconfirmed_rom) {
	print "\n[!] Meter is running an unconfirmed temporary ROM.\n";
	print "Options:\n";
	print "  [C] Confirm the running ROM and retry OTA (Default)\n";
	print "  [R] Restart meter (reverts to previous ROM) and retry OTA\n";
	print "  [A] Abort\n";
	print "Choose an action [C/r/a]: ";
	
	my $ans = <STDIN>;
	chomp($ans) if defined $ans;
	$ans //= 'c';

	if ($ans =~ /^r/i) {
		print "\nSending 'restart' command to revert to previous ROM...\n";
		
		# Send restart with retries (3 tries, 5s timeout each)
		my ($ok, $res) = send_command_with_retry('restart', '', 5, 3, 1);
		
		if ($ok) {
			print "Meter acknowledged restart: $res\n";
		} else {
			print "Warning: Meter did not acknowledge restart, but it may have rebooted immediately.\n";
		}

		if (wait_for_meter(15)) {
			print "\nMeter reverted successfully! Retrying OTA upgrade...\n\n";
			($success, $ota_error, $unconfirmed_rom) = execute_ota();
		} else {
			die "\nFailed: Meter did not come back online after restart.\n";
		}
	}
	elsif ($ans =~ /^c/i || $ans eq '') {
		print "\nSending 'action=confirm' to meter via ota_upgrade...\n";
		
		# Send confirm with retries (3 tries, 5s timeout each)
		my ($confirm_ok, $res) = send_command_with_retry('ota_upgrade', 'action=confirm', 5, 3, 1);

		if ($confirm_ok) {
			print "Meter response: $res\n";
			print "ROM confirmed successfully! Allowing meter to settle...\n";
			
			# IMPORTANT: Give the ESP8266 time to run garbage collection after the flash write
			sleep 5;
			
			print "Retrying OTA upgrade...\n\n";
			($success, $ota_error, $unconfirmed_rom) = execute_ota();
		} else {
			die "\nFailed: Could not confirm ROM (no response after 3 retries).\n";
		}
	} 
	else {
		die "\nAborted by user.\n";
	}
}

if (!$success) {
	die "\nFailed: Command timed out or queue error occurred.\n";
}
if ($ota_error) {
	die "\nFailed: Meter aborted the OTA upgrade. See output above.\n";
}

# Final check after a successful flash - 60 seconds to cover the 22s reboot timer + flash time
if (!wait_for_meter(60)) {
	die "\nWarning: Meter did not come back online within the expected time. It may have failed to boot the new ROM and safely reverted to the old one.\n";
}

print "\nOTA Upgrade Pipeline Completed Successfully.\n";

1;
