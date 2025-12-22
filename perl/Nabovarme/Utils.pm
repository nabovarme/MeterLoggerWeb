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

	my ($latest_energy, $prev_energy, $setup_value, $paid_kwh, $valve_status, $valve_installed, $sw_version);

	# --- Fetch latest sample and valve_status ---
	my $sth = $dbh->prepare(qq[
		SELECT sc.energy, m.valve_status, m.valve_installed, m.sw_version
		FROM meters m
		LEFT JOIN samples_cache sc ON m.serial = sc.serial
		WHERE m.serial = $quoted_serial
		ORDER BY sc.`unix_time` DESC
		LIMIT 1
	]);
	$sth->execute;
	($latest_energy, $valve_status, $valve_installed, $sw_version) = $sth->fetchrow_array;
	$latest_energy   ||= 0;
	$valve_status    ||= '';
	$valve_installed ||= 0;
	$sw_version      ||= '';

	# --- Fetch sample from ~24h ago ---
	$sth = $dbh->prepare(qq[
		SELECT energy
		FROM samples_cache
		WHERE serial = $quoted_serial
		  AND `unix_time` <= UNIX_TIMESTAMP(NOW()) - 86400
		ORDER BY `unix_time` DESC
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

	# --- Calculate energy last day and avg energy last day ---
	my $energy_last_day    = $latest_energy - $prev_energy;
	my $avg_energy_last_day;

	if ($prev_energy) {
		# normal case: use difference over 24h
		$avg_energy_last_day = $energy_last_day / 24;
	} else {
		# fallback to same day last year from samples_daily
		$sth = $dbh->prepare(qq[
			SELECT energy
			FROM samples_daily
			WHERE serial = $quoted_serial
			  AND `unix_time` BETWEEN 
			      UNIX_TIMESTAMP(DATE_SUB(NOW(), INTERVAL 1 YEAR)) 
			      AND UNIX_TIMESTAMP(DATE_SUB(DATE_SUB(NOW(), INTERVAL 1 YEAR), INTERVAL 1 DAY))
			ORDER BY `unix_time` DESC
			LIMIT 1
		]);
		$sth->execute;
		my ($prev_year_energy) = $sth->fetchrow_array;
		$avg_energy_last_day = $prev_year_energy ? $prev_year_energy / 24 : 0;
	}

	# --- Format energy values ---
	$energy_last_day     = sprintf("%.2f", $energy_last_day);
	$avg_energy_last_day = sprintf("%.2f", $avg_energy_last_day);

	# --- Calculate kWh remaining ---
	my $kwh_remaining = $paid_kwh - $latest_energy + $setup_value;
	$kwh_remaining = sprintf("%.2f", $kwh_remaining);

	# --- Determine if meter is closed ---
	my $is_closed = ($valve_status eq 'close' || $kwh_remaining <= 0);

	# --- Calculate time_remaining_hours ---
	my $time_remaining_hours;
	if ($sw_version =~ /NO_AUTO_CLOSE/) {
		$time_remaining_hours = undef;
	} elsif ($is_closed) {
		$time_remaining_hours = 0;
	} elsif ($avg_energy_last_day > 0) {
		$time_remaining_hours = $kwh_remaining / $avg_energy_last_day;
	} else {
		$time_remaining_hours = undef;  # infinite
	}

	# --- Human-readable string ---
	my $time_remaining_hours_string = (!defined $time_remaining_hours || $valve_installed == 0)
		? '∞'
		: rounded_duration($time_remaining_hours * 3600);

	# --- Debug info ---
	warn "[DEBUG] Serial=$serial, valve_status=$valve_status, valve_installed=$valve_installed, sw_version=$sw_version, kwh_remaining=$kwh_remaining, avg_energy_last_day=$avg_energy_last_day, time_remaining_hours=" . (defined $time_remaining_hours ? $time_remaining_hours : '∞') . "\n" if $DEBUG;

	# --- Return all calculated values ---
	return {
		kwh_remaining               => $kwh_remaining,
		time_remaining_hours        => $time_remaining_hours,
		time_remaining_hours_string => $time_remaining_hours_string,
		energy_last_day             => $energy_last_day,
		avg_energy_last_day         => $avg_energy_last_day,
		latest_energy               => $latest_energy,
		paid_kwh                    => $paid_kwh,
		setup_value                 => $setup_value,
		valve_status                => $valve_status,
		valve_installed             => $valve_installed,
	};
}

1;
