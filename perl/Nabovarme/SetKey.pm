package Nabovarme::SetKey;

use strict;
use warnings;

use Fcntl qw(:DEFAULT :flock);
use Math::Random::Secure qw(irand);
use Nabovarme::MQTT_RPC;
use Nabovarme::FirmwareSupport qw(firmware_supports parse_firmware_version);
use Nabovarme::Utils;

sub new {
	my $type = shift;
	my %args = @_;
	my $self = {};

	if ($args{rpc}) {
		$self->{rpc} = $args{rpc};
	} else {
		my $rpc = Nabovarme::MQTT_RPC->new();

		if (!$rpc->connect()) {
			log_die("Failed to connect to database.\n");
		}

		$self->{rpc} = $rpc;
	}

	$self->{log_file} = $args{log_file};

	return bless $self, $type;
}

sub _meter_info {
	my $self = shift;
	my $serial = shift;

	my $sth = $self->{rpc}->{dbh}->prepare(qq[
		SELECT id, sw_version, `key` AS old_key
		FROM meters
		WHERE serial = ?
		LIMIT 1
	]);
	$sth->execute($serial);

	return $sth->fetchrow_hashref;
}

# Append a key change record to the optional recovery log.
sub _write_key_log {
	my $self = shift;
	my %record = @_;

	return 1 if !$self->{log_file};

	my $timestamp = scalar localtime;
	my @fields = (
		$timestamp,
		$record{serial} // '',
		$record{old_key} // '',
		$record{new_key} // '',
		$record{status} // '',
		$record{error} // '',
	);

	for (@fields) {
		$_ =~ s/[\t\r\n]/ /g;
	}

	my $line = join("\t", @fields) . "\n";

	sysopen(my $fh, $self->{log_file}, O_WRONLY | O_CREAT | O_APPEND, 0600)
		or log_die("Cannot open key change log $self->{log_file}: $!\n");

	flock($fh, LOCK_EX)
		or log_die("Cannot lock key change log $self->{log_file}: $!\n");

	print {$fh} $line
		or log_die("Cannot write to key change log $self->{log_file}: $!\n");

	close($fh)
		or log_die("Cannot close key change log $self->{log_file}: $!\n");

	return 1;
}

# Remove stale commands and their associated responses.
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

# Generate a cryptographically random 16-byte key as 32 hexadecimal characters.
sub _generate_key {
	my $self = shift;

	return join('', map { sprintf("%02x", irand(256)) } 1..16);
}

# Change the meter key and update the database after acknowledgment.
sub set_key {
	my $self = shift;
	my $serial = shift;

	log_die("Serial number is required.\n")
		if !defined($serial) || $serial eq '';

	my $rpc = $self->{rpc};
	my $dbh = $rpc->{dbh};

	my $meter = $self->_meter_info($serial);

	log_die("Error: Meter $serial does not exist in the database.\n")
		if !$meter;

	my $version = parse_firmware_version($meter->{sw_version});

	log_die(
		"Error: Cannot determine firmware version for meter $serial "
		. "(sw_version: " . ($meter->{sw_version} // 'unknown') . ").\n"
	) if !defined($version);

	log_die("Error: Meter $serial firmware version $version does not support set_key.\n")
		if !firmware_supports($version, 'set_key');

	my $key = $self->_generate_key();
	my $old_key = $meter->{old_key};

	log_info("Changing key for meter $serial (firmware $version).");

	$self->_clear_pending_command($serial, 'set_key');

	# Log both keys before sending the command so the change can be reversed.
	$self->_write_key_log(
		serial  => $serial,
		old_key => $old_key,
		new_key => $key,
		status  => 'PENDING',
	);

	log_info("Sending set_key command to meter $serial.");

	my $response = '';
	my $success;
	my $rpc_error = '';

	{
		local $SIG{INT} = sub {
			die "Interrupted by SIGINT.\n";
		};

		local $SIG{TERM} = sub {
			die "Interrupted by SIGTERM.\n";
		};

		$success = eval {
			$rpc->call({
				serial   => $serial,
				function => 'set_key',
				param    => $key,
				stateful => 1,
				timeout  => 20,
				callback => sub {
					my $res = shift;
					$response = $res->{param} // '';
					log_info("Meter $serial response: $response");
				}
			});
		};

		$rpc_error = $@;
	}

	if ($rpc_error || !$success || $response !~ /(?:^|&)status=ok(?:&|$)/) {
		my $cleanup_error = '';

		eval {
			$self->_clear_pending_command($serial, 'set_key');
		};

		$cleanup_error = $@;

		log_warn("Failed to clean up pending set_key command for meter $serial: $cleanup_error")
			if $cleanup_error;

		my $error =
			"Failed to change key for meter $serial"
			. ($rpc_error ? " ($rpc_error)" : '')
			. (length($response) ? " (response: $response)" : '')
			. ". Database key was not changed.";

		eval {
			$self->_write_key_log(
				serial  => $serial,
				old_key => $old_key,
				new_key => $key,
				status  => 'FAILED',
				error   => $error,
			);
		};

		log_warn("Failed to write failure status to key change log: $@")
			if $@;

		log_die("$error\n");
	}

	log_info("Meter $serial acknowledged key change. Updating database.");

	my $updated = $dbh->do(
		'UPDATE meters SET `key` = ? WHERE serial = ?',
		undef,
		$key,
		$serial
	);

	if (!defined($updated)) {
		my $error = "Meter acknowledged the new key, but updating meters.key failed.";

		eval {
			$self->_write_key_log(
				serial  => $serial,
				old_key => $old_key,
				new_key => $key,
				status  => 'DB_UPDATE_FAILED',
				error   => $error,
			);
		};

		log_warn("Failed to write database update failure to key change log: $@")
			if $@;

		log_die("Failed to update meters.key for meter $serial.\n");
	}

	eval {
		$self->_write_key_log(
			serial  => $serial,
			old_key => $old_key,
			new_key => $key,
			status  => 'COMPLETED',
		);
	};

	log_warn("Failed to write completion status to key change log: $@")
		if $@;

	log_info("Key change completed successfully for meter $serial.");

	return 1;
}

1;
