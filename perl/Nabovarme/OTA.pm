package Nabovarme::OTA;

use strict;
use warnings;
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

# Check that the meter exists before making an RPC call. The original MQTT_RPC
# does not enqueue a command for an unknown serial, but callback calls would
# otherwise keep waiting for a response.
sub _meter_exists {
	my $self = shift;
	my $serial = shift;

	my $sth = $self->{rpc}->{dbh}->prepare(qq[
		SELECT id
		FROM meters
		WHERE serial = ?
		LIMIT 1
	]);
	$sth->execute($serial);

	my ($id) = $sth->fetchrow_array;
	return defined($id) ? 1 : 0;
}

# Remove stale commands and their replies before starting a fresh request.
# The original MQTT_RPC matches replies by serial/function, not by command ID.
sub _clear_pending_command {
	my $self = shift;
	my $serial = shift;
	my $function = shift;
	my $dbh = $self->{rpc}->{dbh};

	$dbh->do(
		"DELETE FROM command_responses WHERE command_id IN "
		. "(SELECT id FROM command_queue WHERE serial = ? AND function = ?)",
		undef,
		$serial,
		$function
	);
	$dbh->do(
		"DELETE FROM command_queue WHERE serial = ? AND function = ?",
		undef,
		$serial,
		$function
	);
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

	die "Error: Meter $serial does not exist in the database.\n"
		if !$self->_meter_exists($serial);

	$self->_log("Querying meter $serial for current running firmware version...\n");

	$self->_clear_pending_command($serial, 'version');

	my $version_res = '';

	my $version_ok = $rpc->call({
		serial   => $serial,
		function => 'version',
		param    => '',
		stateful => 1,
		timeout  => 20,
		callback => sub {
			my $res = shift;
			$version_res = $res->{param} // '';
		}
	});

	if ($version_ok && $version_res ne '') {
		$self->_log("Current Running Version: $version_res\n\n");
	} else {
		die "Failed: Meter did not respond to version request.\n";
	}

	my $ans;

	if ($unattended) {
		$self->_log("Unattended mode enabled: Automatically confirming running ROM.\n");
		$ans = 'y';
	} elsif (ref $args{on_prompt} eq 'CODE') {
		$ans = $args{on_prompt}->($version_res);
	} else {
		# If called programmatically without a callback, assume intent to confirm.
		$ans = 'y';
	}

	$ans //= '';

	if ($ans !~ /^y/i) {
		$self->_log("Aborted by user.\n");
		return 0;
	}

	$self->_log("Sending 'action=confirm' to meter via ota_update...\n");

	$self->_clear_pending_command($serial, 'ota_update');

	my $confirm_res = '';

	my $call_ok = $rpc->call({
		serial   => $serial,
		function => 'ota_update',
		param    => 'action=confirm',
		stateful => 1,
		timeout  => 20,
		callback => sub {
			my $res = shift;
			$confirm_res = $res->{param} // '';
		}
	});

	if ($call_ok && $confirm_res ne '') {
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
		close($fh)
			or die "Error: Cannot close $bin_file.sha256: $!\n";

		my ($hash) = split(/\s+/, $line // '');

		die "Error: Invalid checksum in $bin_file.sha256\n"
			if !defined($hash) || $hash !~ /^[0-9a-fA-F]{64}$/;

		return lc($hash);
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
# Checks DB telemetry activity first, then uses a direct RPC version query.
# When an explicit expected version is supplied, the running version must match.
sub _wait_for_meter {
	my $self = shift;
	my $serial = shift;
	my $poll_interval = shift || 5;
	my $expected_version = shift;

	my $rpc = $self->{rpc};
	my $max_attempts = 6;
	my $rpc_timeout = 10;

	# Set baseline before the grace period to capture early boot telemetry.
	my $reboot_start_time = time();

	# Allow time for flashing, rebooting, and reconnecting to Wi-Fi/MQTT.
	$self->_log(
		"\nWaiting 25 seconds for meter $serial to reboot and re-establish connection...\n"
	);
	sleep 25;

	$self->_log(
		"Polling meter $serial for online status "
		. "(retrying every ${poll_interval}s for up to 2 mins)...\n"
	);

	my $passive_seen = 0;

	for (my $i = 1; $i <= $max_attempts; $i++) {
		# Check 1: Passive DB activity since the reboot started.
		my $sth = $rpc->{dbh}->prepare(qq[
			SELECT last_updated
			FROM meters
			WHERE serial = ?
				AND last_updated >= ?
			LIMIT 1
		]);
		$sth->execute($serial, $reboot_start_time);

		if ($sth->fetchrow_array) {
			$passive_seen = 1;
		}

		$self->_log(
			"  [Attempt $i/$max_attempts] "
			. ($passive_seen
				? "Passive telemetry detected."
				: "No passive telemetry seen in DB yet.")
			. " Querying firmware version...\n"
		);

		# Give the meter time to finish reconnecting before an active RPC.
		sleep $poll_interval;

		$self->_clear_pending_command($serial, 'version');

		my $res_param = '';

		my $call_ok = $rpc->call({
			serial   => $serial,
			function => 'version',
			param    => '',
			stateful => 1,
			timeout  => $rpc_timeout,
			callback => sub {
				my $res = shift;
				$res_param = $res->{param} // '';
			}
		});

		if ($call_ok && $res_param ne '') {
			$self->_log("\n>>> METER IS BACK ONLINE (Direct version query) <<<\n");
			$self->_log("Firmware Version Running: $res_param\n");

			if (
				defined($expected_version)
				&& $expected_version ne ''
				&& $expected_version ne 'latest'
				&& $res_param ne $expected_version
			) {
				$self->_log(
					"ERROR: Expected firmware version '$expected_version', "
					. "but meter reports '$res_param'.\n"
				);

				return 0;
			}

			return 1;
		}
	}

	# Passive telemetry alone cannot verify an explicitly requested version.
	if ($passive_seen && (
		!defined($expected_version)
		|| $expected_version eq ''
		|| $expected_version eq 'latest'
	)) {
		my $v_sth = $rpc->{dbh}->prepare(qq[
			SELECT sw_version
			FROM meters
			WHERE serial = ?
			LIMIT 1
		]);
		$v_sth->execute($serial);

		my ($running_ver) = $v_sth->fetchrow_array;
		$running_ver //= 'Unknown';

		$self->_log(
			"\n>>> METER IS BACK ONLINE (Detected via DB telemetry update) <<<\n"
		);
		$self->_log("Firmware Version Running: $running_ver\n");

		return 1;
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

	# Clear stale OTA commands and their associated responses first.
	$self->_clear_pending_command($serial, 'ota_update');

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

# Execute OTA with automatic retries for transient network errors.
# Returns ($success, $ota_error, $unconfirmed_rom, $is_retryable_error).
sub _execute_ota_with_retries {
	my $self = shift;
	my $serial = shift;
	my $payload = shift;
	my $max_attempts = shift || 3;

	my ($success, $ota_error, $unconfirmed_rom, $is_retryable_error);

	for (my $attempt = 1; $attempt <= $max_attempts; $attempt++) {
		(
			$success,
			$ota_error,
			$unconfirmed_rom,
			$is_retryable_error
		) = $self->_execute_ota($serial, $payload);

		if (!$is_retryable_error || $attempt >= $max_attempts) {
			last;
		}

		$self->_log(
			"\n[!] Network error encountered during OTA update. "
			. "Retrying attempt (" . ($attempt + 1) . "/$max_attempts) "
			. "in 5 seconds...\n\n"
		);

		sleep 5;
	}

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

	my $version = defined($args{version}) ? $args{version} : 'latest';
	my $unattended = $args{unattended} // 0;
	my $unattended_revert = $args{unattended_revert} // 0;

	my $rpc = $self->{rpc};

	die "Error: Meter $serial does not exist in the database.\n"
		if !$self->_meter_exists($serial);

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

	my ($success, $ota_error, $unconfirmed_rom, $is_retryable_error);

	(
		$success,
		$ota_error,
		$unconfirmed_rom,
		$is_retryable_error
	) = $self->_execute_ota_with_retries($serial, $payload, 3);

	# Handle a meter running an unconfirmed temporary ROM.
	if ($ota_error && $unconfirmed_rom) {
		$self->_log("\n[!] Meter is running an unconfirmed temporary ROM.\n");

		my $ans;

		if ($unattended_revert) {
			$self->_log(
				"Unattended revert mode enabled: Restarting meter to revert "
				. "to previous ROM, then retrying OTA...\n"
			);
			$ans = 'r';
		} elsif ($unattended) {
			$self->_log(
				"Unattended mode enabled: Automatically confirming running "
				. "ROM and retrying OTA...\n"
			);
			$ans = 'c';
		} elsif (ref $args{on_unconfirmed} eq 'CODE') {
			$ans = $args{on_unconfirmed}->();
		} else {
			die "\nFailed: Meter is running an unconfirmed ROM "
				. "and no interactive callback was provided. Aborting.\n";
		}

		$ans //= '';

		if ($ans =~ /^r/i) {
			$self->_log("\nSending 'restart' command to revert to previous ROM...\n");

			$self->_clear_pending_command($serial, 'restart');

			my $res_param = '';

			my $restart_ok = $rpc->call({
				serial   => $serial,
				function => 'restart',
				param    => '',
				stateful => 1,
				timeout  => 20,
				callback => sub {
					$res_param = shift->{param} // '';
				}
			});

			$self->_log("Meter acknowledged restart: $res_param\n")
				if $res_param ne '';

			if (!$restart_ok || $res_param eq '') {
				die "\nFailed: Meter did not acknowledge restart.\n";
			}

			if ($self->_wait_for_meter($serial, 5)) {
				$self->_log(
					"\nMeter reverted successfully! Retrying OTA update...\n\n"
				);

				(
					$success,
					$ota_error,
					$unconfirmed_rom,
					$is_retryable_error
				) = $self->_execute_ota_with_retries($serial, $payload, 3);
			} else {
				die "\nFailed: Meter did not come back online after restart.\n";
			}
		}
		elsif ($ans =~ /^c/i || $ans eq '') {
			$self->_log(
				"\nSending 'action=confirm' to meter via ota_update...\n"
			);

			$self->_clear_pending_command($serial, 'ota_update');

			my $res_param = '';

			my $confirm_ok = $rpc->call({
				serial   => $serial,
				function => 'ota_update',
				param    => 'action=confirm',
				stateful => 1,
				timeout  => 20,
				callback => sub {
					my $res = shift;
					$res_param = $res->{param} // '';
				}
			});

			if ($confirm_ok && $res_param ne '') {
				$self->_log("Meter response: $res_param\n");
				$self->_log("ROM confirmed successfully!\n");
				$self->_log("Retrying OTA update...\n\n");

				(
					$success,
					$ota_error,
					$unconfirmed_rom,
					$is_retryable_error
				) = $self->_execute_ota_with_retries($serial, $payload, 3);
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

	# Verify the explicitly selected firmware version after reboot.
	my $expected_version = (
		defined($version)
		&& $version ne ''
		&& $version ne 'latest'
	) ? $version : undef;

	if (!$self->_wait_for_meter($serial, 5, $expected_version)) {
		die "\nWarning: Meter did not return with the expected firmware version. "
			. "It may have failed to boot the new ROM or safely reverted to the old one.\n";
	}

	$self->_log("\nOTA Update Pipeline Completed Successfully.\n");

	return 1;
}

1;
