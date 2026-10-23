
package Nabovarme::SetKey;

use strict;
use warnings;

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

	return bless $self, $type;
}

sub _meter_info {
	my $self = shift;
	my $serial = shift;

	my $sth = $self->{rpc}->{dbh}->prepare(qq[
		SELECT id, sw_version
		FROM meters
		WHERE serial = ?
		LIMIT 1
	]);
	$sth->execute($serial);

	return $sth->fetchrow_hashref;
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

	open(my $fh, '<:raw', '/dev/urandom')
		or log_die("Cannot open /dev/urandom: $!\n");

	my $random_bytes = '';
	my $bytes_read = read($fh, $random_bytes, 16);
	my $close_ok = close($fh);

	log_die("Failed to generate random key.\n")
		if !defined($bytes_read) || $bytes_read != 16;

	log_die("Cannot close /dev/urandom: $!\n")
		if !$close_ok;

	return unpack('H*', $random_bytes);
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

	log_info("Changing key for meter $serial (firmware $version).");
	log_debug("Generated new key for meter $serial: $key");

	$self->_clear_pending_command($serial, 'set_key');

	log_info("Sending set_key command to meter $serial.");

	my $response = '';

	my $success = $rpc->call({
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

	log_die(
		"Failed to change key for meter $serial"
		. (length($response) ? " (response: $response)" : '')
		. ". Database key was not changed.\n"
	) if !$success || $response !~ /(?:^|&)status=ok(?:&|$)/;

	log_info("Meter $serial acknowledged key change. Updating database.");

	my $updated = $dbh->do(
		'UPDATE meters SET `key` = ? WHERE serial = ?',
		undef,
		$key,
		$serial
	);

	log_die("Failed to update meters.key for meter $serial.\n")
		if !defined($updated);

	log_info("Key change completed successfully for meter $serial.");

	return 1;
}

1;
