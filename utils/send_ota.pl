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

die "Error: Firmware directory not found: $fw_dir\n" if (!-d $fw_dir);

sub get_hash {
	my $bin_file = shift;
	die "Error: Firmware binary not found: $bin_file\n" if (!-f $bin_file);

	if (-f "$bin_file.sha256") {
		open(my $fh, '<', "$bin_file.sha256") or die "Error: Cannot open $bin_file.sha256: $!\n";
		my $line = <$fh>;
		close($fh);
		my ($hash) = split(/\s+/, $line);
		return $hash;
	} else {
		my $output = `sha256sum $bin_file`;
		my ($hash) = split(/\s+/, $output);
		return $hash;
	}
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

# Subroutine to wait for meter to reboot and come online
sub wait_for_meter {
	my $delay = shift || 15;
	print "\nWaiting for meter to download firmware, flash, and reboot ($delay seconds)...\n";
	sleep $delay;

	print "Pinging meter to verify it comes back online (Retrying for ~2 mins)...\n";
	
	# Loop 10 times, giving the backend dispatcher 15 seconds (1-2 retries) per attempt
	for (my $i = 1; $i <= 10; $i++) {
		my $res_param = '';
		
		# Clear queue before pinging to prevent buildup
		$rpc->{dbh}->do("DELETE FROM command_queue WHERE serial = ? AND function = 'version'", undef, $serial);
		$rpc->call({
			serial   => $serial,
			function => 'version',
			param    => '',
			stateful => 0,
			timeout  => 15, # Allows background dispatcher time to retransmit
			callback => sub {
				my $res = shift;
				$res_param = $res->{param};
			}
		});
		
		if (defined $res_param &&$res_param ne '') {
			print "\n>>> METER IS BACK ONLINE <<<\n";
			print "Firmware Version Running: $res_param\n";
			return 1;
		}
		print "  No response. Retrying ($i/10)...\n" if $i < 10;
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
			
			if ($msg =~ /error_unconfirmed_temp_rom/i) {
				$unconfirmed_rom = 1;
				$ota_error = 1;
				return 0; # Exit continuous mode
			}
			elsif ($msg =~ /error/i || $msg =~ /fail/i) {
				$ota_error = 1;
				return 0; # Exit continuous mode
			}
			
			# Exit ONLY when flashing is finished or reboot countdown starts
			if ($msg =~ /success/i || $msg =~ /staging/i || $msg =~ /complete/i || $msg =~ /100\%/ || $msg =~ /permanently/i || $msg =~ /pending_confirmation/i || $msg =~ /restarting/i) {
				print "\n[+] Meter OTA flashing complete. Preparing to reboot...\n";
				return 0; # Exit continuous mode
			}
			
			return 1; # Continue listening
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
		$rpc->{dbh}->do("DELETE FROM command_queue WHERE serial = ? AND function = 'restart'", undef, $serial);
		
		my $res_param = '';
		$rpc->call({
			serial   => $serial,
			function => 'restart',
			param    => '',
			stateful => 1,
			timeout  => 15,
			callback => sub { $res_param = shift->{param}; }
		});
		
		if ($res_param) {
			print "Meter acknowledged restart: $res_param\n";
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
		$rpc->{dbh}->do("DELETE FROM command_queue WHERE serial = ? AND function = 'ota_upgrade'", undef, $serial);
		
		my $res_param = '';
		$rpc->call({
			serial   => $serial,
			function => 'ota_upgrade',
			param    => 'action=confirm',
			stateful => 1,
			timeout  => 15,
			callback => sub { $res_param = shift->{param}; }
		});

		if (defined $res_param &&$res_param ne '') {
			print "Meter response: $res_param\n";
			print "ROM confirmed successfully! Allowing meter to settle...\n";
			sleep 5;
			print "Retrying OTA upgrade...\n\n";
			($success, $ota_error, $unconfirmed_rom) = execute_ota();
		} else {
			die "\nFailed: Could not confirm ROM (no response).\n";
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

# Final check after a successful flash - 35 seconds to cover the 22s reboot timer + flash time
if (!wait_for_meter(35)) {
	die "\nWarning: Meter did not come back online within the expected time. It may have failed to boot the new ROM and safely reverted to the old one.\n";
}

print "\nOTA Upgrade Pipeline Completed Successfully.\n";

1;
