package Nabovarme::Utils;

use strict;
use warnings;
use utf8;
use Exporter 'import';
use POSIX qw(floor);

our @EXPORT = qw(rounded_duration estimate_remaining_energy);

# Read debug flag from environment variable
my $DEBUG = $ENV{ENABLE_DEBUG} || 0;

# ----------------------------
# Format seconds into readable duration
# ----------------------------
sub rounded_duration {
	my $seconds = shift;
	return '∞' unless defined $seconds;

	my $is_negative = $seconds < 0;
	$seconds = abs($seconds);

	my $result;
	if ($seconds >= 86400) {
		my $days = int(($seconds + 43200) / 86400);
		$result = $days == 1 ? "1 day" : "$days days";
	}
	elsif ($seconds >= 3600) {
		my $hours = int(($seconds + 1800) / 3600);
		$result = $hours == 1 ? "1 hour" : "$hours hours";
	}
	elsif ($seconds >= 60) {
		my $minutes = int(($seconds + 30) / 60);
		$result = $minutes == 1 ? "1 minute" : "$minutes minutes";
	}
	elsif ($seconds == 0) {
		$result = "0 days";
	}
	else {
		my $secs = int($seconds + 0.5);
		$result = $secs == 1 ? "1 second" : "$secs seconds";
	}

	return $is_negative ? "$result ago" : $result;
}

# ----------------------------
# Estimate remaining energy and time left
# ----------------------------
sub estimate_remaining_energy {
	my ($dbh, $serial) = @_;
	return {} unless $dbh && $serial;

	my $quoted_serial = $dbh->quote($serial);

	my ($latest_energy, $latest_effect, $prev_energy, $setup_value, $paid_kwh, $valve_status);

	# --- Fetch latest sample and valve_status ---
	my $sth = $dbh->prepare(qq[
		SELECT energy, effect, valve_status
		FROM meters m
		LEFT JOIN samples_cache sc ON m.serial = sc.serial
		WHERE m.serial = $quoted_serial
		ORDER BY sc.unix_time DESC
		LIMIT 1
	]);
	$sth->execute;
	($latest_energy, $latest_effect, $valve_status) = $sth->fetchrow_array;

	$latest_energy  ||= 0;
	$latest_effect  ||= 0;
	$valve_status   ||= '';

	# --- Fetch sample from ~24h ago ---
	$sth = $dbh->prepare(qq[
		SELECT energy
		FROM samples_cache
		WHERE serial = $quoted_serial
		  AND unix_time <= UNIX_TIMESTAMP(NOW()) - 86400
		ORDER BY unix_time DESC
		LIMIT 1
	]);
	$sth->execute;
	($prev_energy) = $sth->fetchrow_array;
	$prev_energy ||= 0;

	# --- Fetch meter setup_value ---
	$sth = $dbh->prepare(qq[
		SELECT setup_value
		FROM meters
		WHERE serial = $quoted_serial
	]);
	$sth->execute;
	($setup_value) = $sth->fetchrow_array;
	$setup_value ||= 0;

	# --- Fetch paid kWh from accounts ---
	$sth = $dbh->prepare(qq[
		SELECT SUM(amount / price)
		FROM accounts
		WHERE serial = $quoted_serial
	]);
	$sth->execute;
	($paid_kwh) = $sth->fetchrow_array;
	$paid_kwh ||= 0;

	# --- Fetch valve_installed ---
	$sth = $dbh->prepare(qq[
		SELECT valve_installed
		FROM meters
		WHERE serial = $quoted_serial
	]);
	$sth->execute;
	my ($valve_installed) = $sth->fetchrow_array;
	$valve_installed ||= 0;

	# --- Calculate energy last day and avg energy last day ---
	my $energy_last_day     = sprintf("%.2f", $latest_energy - $prev_energy);
	my $avg_energy_last_day = sprintf("%.2f", ($latest_energy - $prev_energy) / 24);

	# --- Fallback if no recent 24h sample ---
	if ($energy_last_day == 0 && $latest_effect > 0) {
		$energy_last_day     = sprintf("%.2f", 0);
		$avg_energy_last_day = sprintf("%.2f", $latest_effect);
	}

	# --- Calculate kWh remaining ---
	my $kwh_remaining = int($paid_kwh - $latest_energy + $setup_value + 0.5);

	# --- Determine if meter is closed ---
	my $is_closed = ($valve_status eq 'close' || $kwh_remaining <= 0);

	# --- Calculate time remaining hours ---
	my $time_remaining_hours;
	if ($is_closed) {
		$time_remaining_hours = 0;
	} elsif ($latest_effect > 0) {
		$time_remaining_hours = $kwh_remaining / $latest_effect;
	} elsif ($avg_energy_last_day > 0) {
		$time_remaining_hours = $kwh_remaining / $avg_energy_last_day;
	} else {
		$time_remaining_hours = '∞';
	}

	# --- Human-readable string ---
	my $time_remaining_hours_string;
	if ($time_remaining_hours eq '∞' || $valve_installed == 0) {
		$time_remaining_hours_string = '∞';
	} else {
		$time_remaining_hours_string = rounded_duration($time_remaining_hours * 3600);
	}

	# --- Debug info (optional) ---
	warn "[DEBUG] Serial=$serial, valve_status=$valve_status, valve_installed=$valve_installed, kwh_remaining=$kwh_remaining, latest_effect=$latest_effect, avg_energy_last_day=$avg_energy_last_day, time_remaining_hours=$time_remaining_hours\n" if $DEBUG;

	# --- Return all calculated values ---
	return {
		kwh_remaining               => $kwh_remaining,
		time_remaining_hours        => $time_remaining_hours eq '∞' ? '∞' : sprintf("%.2f", $time_remaining_hours),
		time_remaining_hours_string => $time_remaining_hours_string,
		energy_last_day             => $energy_last_day,
		avg_energy_last_day         => $avg_energy_last_day,
		latest_effect               => $latest_effect,
		latest_energy               => $latest_energy,
		paid_kwh                    => $paid_kwh,
		setup_value                 => $setup_value,
		valve_status                => $valve_status,
		valve_installed             => $valve_installed,
	};
}

1;
