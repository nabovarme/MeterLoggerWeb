#!/usr/bin/perl

use strict;
use warnings;

use DBI;
use Nabovarme::Db;
use Nabovarme::MQTT_RPC;
use Nabovarme::Utils;

use constant RPC_TIMEOUT => 60;
use constant LOG_FILE => 'meter_key_rotation.log';

sub log_result {
	my ($message) = @_;

	my $timestamp = scalar localtime;
	my $line = "[$timestamp] $message\n";

	print $line;

	if (open my $fh, '>>', LOG_FILE) {
		print {$fh} $line;
		close $fh;
	}
	else {
		warn "Unable to write " . LOG_FILE . ": $!\n";
	}
}

sub usage {
	die "Usage: $0 <serial> <new_32_char_hex_key>\n";
}

my ($serial, $new_key) = @ARGV;
usage() unless defined $serial && defined $new_key;
usage() unless $new_key =~ /\A[0-9a-fA-F]{32}\z/;

my $dbh = Nabovarme::Db->my_connect
	or die "Unable to connect to database\n";

my $sth = $dbh->prepare(qq[
	SELECT `key`
	FROM meters
	WHERE serial = ?
	LIMIT 1
]);

$sth->execute($serial);
my ($old_key) = $sth->fetchrow_array;

unless (defined $old_key && length $old_key) {
	log_result("FAILED: No existing key found for meter $serial");
	exit 1;
}

if (lc($old_key) eq lc($new_key)) {
	log_result("FAILED: New key is identical to current key for meter $serial");
	exit 1;
}

my $mqtt = Nabovarme::MQTT_RPC->new;
$mqtt->connect() or die "Unable to connect to MQTT RPC\n";

log_result("Requesting key change for meter $serial");

my $callback_called = 0;
my $success = 0;

$mqtt->call({
	serial   => $serial,
	function => 'set_key',
	param    => "key=$new_key",
	stateful => 1,
	callback => sub {
		my ($response) = @_;

		$callback_called = 1;

		my $response_param = ref($response) eq 'HASH'
			? ($response->{param} // '')
			: '';

		if ($response_param =~ /\Astatus=ok(?:\s|\z)/) {
			my $update = $dbh->prepare(qq[
				UPDATE meters
				SET `key` = ?
				WHERE serial = ?
					AND `key` = ?
			]);

			$update->execute($new_key, $serial, $old_key);

			if ($update->rows == 1) {
				$success = 1;
				log_result(
					"SUCCESS: Key changed for meter $serial; " .
					"old_key=$old_key new_key=$new_key"
				);
			}
			else {
				log_result(
					"ERROR: Meter $serial acknowledged the key change, " .
					"but the database key was not updated; " .
					"the stored key may have changed concurrently; " .
					"old_key=$old_key new_key=$new_key"
				);
			}
		}
		elsif ($response_param =~ /\Astatus=error_invalid_key(?:\s|\z)/) {
			log_result(
				"FAILED: Meter $serial rejected the new key " .
				"(status=error_invalid_key); " .
				"old_key=$old_key attempted_key=$new_key"
			);
		}
		else {
			log_result(
				"FAILED: Unexpected response from meter $serial: " .
				($response_param || '(empty response)')
			);
		}

		return 0;
	},
	timeout => RPC_TIMEOUT,
});

unless ($callback_called) {
	log_result(
		"TIMEOUT/FAILURE: No callback received for meter $serial; " .
		"database key left unchanged; " .
		"old_key=$old_key attempted_key=$new_key"
	);
}

exit($success ? 0 : 1);
