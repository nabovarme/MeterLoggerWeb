package Nabovarme::OTA;

use strict;
use Digest::SHA;
use Nabovarme::MQTT_RPC;

sub new {
	my $type = shift;
	my %args = @_;
	my $self = {};

	if ($args{rpc}) {
		$self->{rpc} = $args{rpc};
	} else {
		my $rpc = Nabovarme::MQTT_RPC->new();

		if (!$rpc->connect()) {
			die "Failed to connect to database.\n";
		}

		$self->{rpc} = $rpc;
	}

	$self->{logger} = $args{logger};
	$self->{input}  = $args{input};

	return bless $self, $type;
}

sub _log {
	my $self = shift;
	my $message = shift;

	if (ref($self->{logger}) eq 'CODE') {
		$self->{logger}->($message);
	} else {
		print $message;
	}
}

sub _read_input {
	my $self = shift;
	my $prompt = shift;

	$self->_log($prompt);

	if (ref($self->{input}) eq 'CODE') {
		return $self->{input}->();
	}

	return scalar <STDIN>;
}

# Query the running firmware and interactively confirm the current ROM.
# Returns 1 on confirmation and 0 if the user declines.
sub confirm {
	my $self   = shift;
	my $serial = shift;
	my %args   = @_;

	die "Serial number is required.\n"
		if !defined($serial) || $serial eq '';

	my $unattended = $args{unattended} // 0;
	my $rpc        = $self->{rpc};

	$self->_log("Querying meter $serial for current running firmware version...\n");

	$rpc->{dbh}->do(
		"DELETE FROM command_queue WHERE serial = ? AND function = 'version'",
		undef,
		$serial
	);

	my $version_res = '';

	$rpc->call({
		serial   => $serial,
		function => 'version',
		param    => '',
		stateful => 0,
		timeout  => 20,
		callback => sub {
			my $res = shift;
			$version_res = $res->{param};
		}
	});

	if (defined($version_res) && $version_res ne '') {
		$self->_log("Current Running Version: $version_res\n\n");
	} else {
		die "Failed: Meter did not respond to version request.\n";
	}

	my $ans;

	if ($unattended) {
		$self->_log("Unattended mode enabled: Automatically confirming running ROM.\n");
		$ans = 'y';
	} else {
		$ans = $self->_read_input(
			"Are you sure you want to confirm this running ROM permanently? [y/N]: "
		);
		chomp($ans) if defined $ans;
		$ans //= 'n';
	}

	if ($ans !~ /^y/i) {
		$self->_log("Aborted by user.\n");
		return 0;
	}

	$self->_log("Sending 'action=confirm' to meter via ota_update...\n");

	$rpc->{dbh}->do(
		"DELETE FROM command_queue WHERE serial = ? AND function = 'ota_update'",
		undef,
		$serial
	);

	my $confirm_res = '';

	$rpc->call({
		serial   => $serial,
		function => 'ota_update',
		param    => 'action=confirm',
		stateful => 1,
		timeout  => 20,
		callback => sub {
			my $res = shift;
			$confirm_res = $res->{param};
		}
	});

	if (defined($confirm_res) && $confirm_res ne '') {
		$self->_log("Meter Response: $confirm_res\n");
		$self->_log("ROM confirmed successfully.\n");
	} else {
		die "Failed: Could not confirm ROM (no response).\n";
	}

	return 1;
}

# Return a SHA-256 checksum from a sidecar file or calculate it.
sub _get_hash {
	my $self = shift;
	my $bin_file = shift;

	die "Error: Firmware binary not found: $bin_file\n"
		if !-f $bin_file;

	if (-f "$bin_file.sha256") {
		open(my $fh, '<', "$bin_file.sha256")
			or die "Error: Cannot open $bin_file.sha256: $!\n";

		my $line = <$fh>;
		close($fh);

		my ($hash) = split(/\s+/, $line // '');

		die "Error: Invalid checksum in $bin_file.sha256\n"
			if !defined($hash) || $hash !~ /^[0-9a-fA-F]{64}$/;

		return $hash;
	} else {
		my $sha = Digest::SHA->new(256);

		open(my $fh, '<:raw', $bin_file)
			or die "Error: Cannot open $bin_file: $!\n";

		$sha->addfile($fh);

		close($fh)
			or die "Error: Cannot close $bin_file: $!\n";

		return $sha->hexdigest();
	}
}

# Wait for the meter to reboot and verify that it comes back online.
# Checks DB telemetry activity first, then falls back to active RPC version checks.
sub _wait_for_meter {
	my $self = shift;
	my $serial = shift;
	my $poll_interval = shift || 5;

	my $rpc = $self->{rpc};
	my $max_attempts = 36;          # 36 attempts * 5s = 3 minutes total
	my $rpc_timeout = 5;

	# Mandatory 20-second grace delay to allow the meter to stop execution and reboot,
	# preventing stale telemetry published right before restart from causing false positives.
	$self->_log("\nWaiting 20 seconds for meter $serial to shut down, flash, and reboot...\n");
	sleep 20;

	my $reboot_start_time = time(); # Set baseline timestamp AFTER the grace period

	$self->_log("Polling meter $serial for online status (retrying every ${poll_interval}s for up to 3 mins)...\n");

	for (my $i = 1; $i <= $max_attempts; $i++) {
		# Check 1: Passive DB Activity Check (telemetry/syslog update since reboot)
		my $sth = $rpc->{dbh}->prepare(qq[
			SELECT last_updated 
			FROM meters 
			WHERE serial = ? 
			AND last_updated >= ? 
			LIMIT 1
		]);
		$sth->execute($serial, $reboot_start_time);

		if ($sth->rows) {
			# Fetch running version string for logging display
			my $v_sth = $rpc->{dbh}->prepare(qq[SELECT sw_version FROM meters WHERE serial = ? LIMIT 1]);
			$v_sth->execute($serial);
			my ($running_ver) = $v_sth->fetchrow_array;
			$running_ver //= 'Unknown';

			$self->_log("\n>>> METER IS BACK ONLINE (Detected via DB telemetry update) <<<\n");
			$self->_log("Firmware Version Running: $running_ver\n");
			return 1;
		}

		# Check 2: Active RPC Version Query
		$rpc->{dbh}->do(
			"DELETE FROM command_queue WHERE serial = ? AND function = 'version'",
			undef,
			$serial
		);

		my $res_param = '';

		$rpc->call({
			serial   => $serial,
			function => 'version',
			param    => '',
			stateful => 1,          # Force stateful insertion to guarantee fresh delivery
			timeout  => $rpc_timeout,
			callback => sub {
				my $res = shift;
				$res_param = $res->{param};
			}
		});

		if (defined($res_param) && $res_param ne '') {
			$self->_log("\n>>> METER IS BACK ONLINE (Detected via direct version query) <<<\n");
			$self->_log("Firmware Version Running: $res_param\n");
			return 1;
		}

		$self->_log("  [Attempt $i/$max_attempts] No response yet. Retrying in ${poll_interval}s...\n");
		sleep $poll_interval;
	}

	return 0;
}

# Execute a single OTA update attempt.
# Returns ($success, $ota_error, $unconfirmed_rom, $is_retryable_error).
sub _execute_ota {
	my $self = shift;
	my $serial = shift;
	my $payload = shift;

	my $rpc = $self->{rpc};

	$self->_log("Dispatching OTA Update command for serial $serial...\n");
	$self->_log('-' x 50 . "\n");

	my $ota_error = 0;
	my $unconfirmed_rom = 0;
	my $is_retryable_error = 0;

	# Clear any old OTA commands before starting.
	$rpc->{dbh}->do(
		"DELETE FROM command_queue WHERE serial = ? AND function = 'ota_update'",
		undef,
		$serial
	);

	my $success = $rpc->call({
		serial     => $serial,
		function   => 'ota_update',
		param      => $payload,
		stateful   => 1,
		continuous => 1,
		timeout    => 300,
		callback   => sub {
			my $res = shift;
			my $msg = defined($res->{param}) ? $res->{param} : '';

			$self->_log("Meter: $msg\n") if $msg ne $payload;

			if ($msg =~ /error_unconfirmed_temp_rom/i) {
				$unconfirmed_rom = 1;
				$ota_error = 1;
				return 0;
			}
			# Classify transient network errors reported by the firmware.
			elsif (
				$msg =~ /(?:^|[\s&])status=error_(?:tcp_drop|timeout|disconnected|dns)\b/i
				|| $msg =~ /error_(?:tcp_drop|timeout|disconnected|dns)\b/i
			) {
				$ota_error = 1;
				$is_retryable_error = 1;
				return 0;
			}
			elsif ($msg =~ /error/i || $msg =~ /fail/i) {
				$ota_error = 1;
				return 0;
			}

			# Stop listening when flashing finishes or the reboot countdown starts.
			if (
				$msg =~ /success/i
				|| $msg =~ /staging/i
				|| $msg =~ /complete/i
				|| $msg =~ /100\%/
				|| $msg =~ /permanently/i
				|| $msg =~ /pending_confirmation/i
				|| $msg =~ /restarting/i
			) {
				$self->_log(
					"\n[+] Meter OTA flashing complete. Preparing to reboot...\n"
				);
				return 0;
			}

			return 1;
		}
	});

	$self->_log('-' x 50 . "\n");

	return (
		$success,
		$ota_error,
		$unconfirmed_rom,
		$is_retryable_error
	);
}

# Update a meter to the selected firmware version.
# Returns 1 on success. Dies if the update fails or is aborted.
sub update {
	my $self = shift;
	my $serial = shift;
	my %args = @_;

	die "Serial number is required.\n"
		if !defined($serial) || $serial eq '';

	my $version    = defined($args{version}) ? $args{version} : 'latest';
	my $unattended = $args{unattended} // 0;
	my $unattended_revert = $args{unattended_revert} // 0;

	my $rpc = $self->{rpc};

	my $fw_dir = "/home/meterlogger/firmware/$serial/$version";

	# Fall back to the root serial directory if 'latest' is unavailable.
	if (
		!-d $fw_dir
		&& $version eq 'latest'
		&& -d "/home/meterlogger/firmware/$serial"
	) {
		$fw_dir = "/home/meterlogger/firmware/$serial";
		$version = '';
	}

	die "Error: Firmware directory not found: $fw_dir\n"
		if !-d $fw_dir;

	$self->_log("Reading/calculating checksums from $fw_dir...\n");

	my $sha1 = $self->_get_hash("$fw_dir/user1.ota.bin");
	my $sha2 = $self->_get_hash("$fw_dir/user2.ota.bin");

	# Construct the exact OTA payload expected by the meter.
	my $payload = "version=$version&sha1=$sha1&sha2=$sha2";

	# Initial execution with automatic retries for transient network failures.
	my $max_ota_attempts = 3;
	my ($success, $ota_error, $unconfirmed_rom, $is_retryable_error);

	for (my $attempt = 1; $attempt <= $max_ota_attempts; $attempt++) {
		(
			$success,
			$ota_error,
			$unconfirmed_rom,
			$is_retryable_error
		) = $self->_execute_ota($serial, $payload);

		if (
			$is_retryable_error
			&& $attempt < $max_ota_attempts
		) {
			$self->_log(
				"\n[!] Network error encountered during OTA update. "
				. "Retrying attempt (" . ($attempt + 1) . "/$max_ota_attempts) in 5 seconds...\n\n"
			);

			sleep 5;
			next;
		}

		last;
	}

	# Handle a meter running an unconfirmed temporary ROM.
	if ($ota_error && $unconfirmed_rom) {
		$self->_log("\n[!] Meter is running an unconfirmed temporary ROM.\n");

		my $ans;

		if ($unattended_revert) {
			$self->_log("Unattended revert mode enabled: Restarting meter to revert to previous ROM, then retrying OTA...\n");
			$ans = 'r';
		} elsif ($unattended) {
			$self->_log("Unattended mode enabled: Automatically confirming running ROM and retrying OTA...\n");
			$ans = 'c';
		} else {
			$self->_log("Options:\n");
			$self->_log("  [C] Confirm the running ROM and retry OTA (Default)\n");
			$self->_log("  [R] Restart meter (reverts to previous ROM) and retry OTA\n");
			$self->_log("  [A] Abort\n");

			$ans = $self->_read_input("Choose an action [C/r/a]: ");
			chomp($ans) if defined $ans;
			$ans //= 'c';
		}

		if ($ans =~ /^r/i) {
			$self->_log("\nSending 'restart' command to revert to previous ROM...\n");

			$rpc->{dbh}->do(
				"DELETE FROM command_queue WHERE serial = ? AND function = 'restart'",
				undef,
				$serial
			);

			my $res_param = '';

			$rpc->call({
				serial   => $serial,
				function => 'restart',
				param    => '',
				stateful => 1,
				timeout  => 20,
				callback => sub {
					$res_param = shift->{param};
				}
			});

			$self->_log("Meter acknowledged restart: $res_param\n")
				if $res_param;

			if ($self->_wait_for_meter($serial, 20)) {
				$self->_log(
					"\nMeter reverted successfully! Retrying OTA update...\n\n"
				);

				(
					$success,
					$ota_error,
					$unconfirmed_rom,
					$is_retryable_error
				) = $self->_execute_ota($serial, $payload);
			} else {
				die "\nFailed: Meter did not come back online after restart.\n";
			}
		}
		elsif ($ans =~ /^c/i || $ans eq '') {
			$self->_log(
				"\nSending 'action=confirm' to meter via ota_update...\n"
			);

			$rpc->{dbh}->do(
				"DELETE FROM command_queue WHERE serial = ? AND function = 'ota_update'",
				undef,
				$serial
			);

			my $res_param = '';

			$rpc->call({
				serial   => $serial,
				function => 'ota_update',
				param    => 'action=confirm',
				stateful => 1,
				timeout  => 20,
				callback => sub {
					my $res = shift;
					$res_param = $res->{param};
				}
			});

			if (defined($res_param) && $res_param ne '') {
				$self->_log("Meter response: $res_param\n");
				$self->_log(
					"ROM confirmed successfully!\n"
				);

				$self->_log("Retrying OTA update..\n\n");

				(
					$success,
					$ota_error,
					$unconfirmed_rom,
					$is_retryable_error
				) = $self->_execute_ota($serial, $payload);
			} else {
				die "\nFailed: Could not confirm ROM (no response).\n";
			}
		} else {
			die "\nAborted by user.\n";
		}
	}

	if (!$success) {
		die "\nFailed: Command timed out or queue error occurred.\n";
	}

	if ($ota_error) {
		die "\nFailed: Meter aborted the OTA update. See output above.\n";
	}

	# Allow for the reboot countdown and firmware boot time.
	if (!$self->_wait_for_meter($serial, 20)) {
		die "\nWarning: Meter did not come back online within the expected time. "
			. "It may have failed to boot the new ROM and safely reverted to the old one.\n";
	}

	$self->_log("\nOTA Update Pipeline Completed Successfully.\n");

	return 1;
}

1;
