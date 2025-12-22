package Nabovarme::Utils;

use strict;
use warnings;
use utf8;
use Exporter 'import';
use POSIX qw(floor);

our @EXPORT = qw(rounded_duration estimate_remaining_energy);

# ----------------------------
# Runtime debug helper
# ----------------------------
sub is_debug { 
	return ($ENV{ENABLE_DEBUG} // '') =~ /^(1|true)$/i; 
}

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

	warn "[DEBUG] Latest sample fetched: latest_energy=$latest_energy, valve_status=$valve_status, valve_installed=$valve_installed, sw_version=$sw_version\n" if is_debug();

	# --- Fetch sample from ~24h ago ---
	$sth = $dbh->prepare(qq[
		SELECT energy, `unix_time`
		FROM samples_cache
		WHERE serial = $quoted_serial
		  AND `unix_time` <= UNIX_TIMESTAMP(NOW()) - 86400
		ORDER BY `unix_time` DESC
		LIMIT 1
	]);
	$sth->execute;
	my ($prev_energy_sample, $prev_unix_time) = $sth->fetchrow_array;
	$prev_energy_sample ||= 0;

	my $use_fallback = 0;
	if ($prev_energy_sample == $latest_energy) {
		warn "[DEBUG] latest_energy == prev_energy ($latest_energy) => using fallback\n" if is_debug();
		$use_fallback = 1;
	} elsif ($prev_unix_time && (time() - $prev_unix_time) < 12*3600) {
		warn "[DEBUG] Previous sample less than 12 hours old => using fallback\n" if is_debug();
		$use_fallback = 1;
	}

	$prev_energy = $use_fallback ? 0 : $prev_energy_sample;
	warn "[DEBUG] Previous energy used: $prev_energy\n" if is_debug();

	# --- Fetch meter setup_value ---
	$sth = $dbh->prepare(qq[
		SELECT setup_value
		FROM meters
		WHERE serial = $quoted_serial
	]);
	$sth->execute;
	($setup_value) = $sth->fetchrow_array;
	$setup_value ||= 0;
	warn "[DEBUG] Setup value=$setup_value\n" if is_debug();

	# --- Fetch paid kWh from accounts ---
	$sth = $dbh->prepare(qq[
		SELECT SUM(amount / price)
		FROM accounts
		WHERE serial = $quoted_serial
	]);
	$sth->execute;
	($paid_kwh) = $sth->fetchrow_array;
	$paid_kwh ||= 0;
	warn "[DEBUG] Paid kWh=$paid_kwh\n" if is_debug();

	# --- Calculate energy last day and avg energy last day ---
	my ($energy_last_day, $avg_energy_last_day);

	if (!$use_fallback && $prev_energy) {
		# Normal path: use difference over 24h
		$energy_last_day    = $latest_energy - $prev_energy;
		$avg_energy_last_day = $energy_last_day / 24;
		warn "[DEBUG] Using normal 24h average for avg_energy_last_day=$avg_energy_last_day\n" if is_debug();
	} else {
		# Fallback: average effect from samples_daily for same day in previous years
		$sth = $dbh->prepare(qq[
			SELECT AVG(effect) AS avg_daily_usage, COUNT(*) AS years_count
			FROM samples_daily
			WHERE serial = $quoted_serial
			  AND DAYOFYEAR(FROM_UNIXTIME(unix_time)) = DAYOFYEAR(DATE_SUB(NOW(), INTERVAL 1 DAY))
			  AND YEAR(FROM_UNIXTIME(unix_time)) < YEAR(NOW())
		]);
		$sth->execute;
		my ($avg_daily_usage, $years_count) = $sth->fetchrow_array;
		$avg_daily_usage ||= 0;

		warn "[DEBUG] Fallback: avg_daily_usage=$avg_daily_usage from $years_count previous years\n" if is_debug();

		$energy_last_day     = $avg_daily_usage;        # daily total usage
		$avg_energy_last_day = $avg_daily_usage;        # do NOT divide by 24
		warn "[DEBUG] Using fallback from samples_daily.effect, energy_last_day=$energy_last_day, avg_energy_last_day=$avg_energy_last_day\n" if is_debug();
	}

	# --- Format energy values ---
	$energy_last_day     = sprintf("%.2f", $energy_last_day);
	$avg_energy_last_day = sprintf("%.2f", $avg_energy_last_day);
	warn "[DEBUG] Energy last day=$energy_last_day, avg_energy_last_day=$avg_energy_last_day\n" if is_debug();

	# --- Calculate kWh remaining ---
	my $kwh_remaining = $paid_kwh - $latest_energy + $setup_value;
	$kwh_remaining = sprintf("%.2f", $kwh_remaining);
	warn "[DEBUG] kWh remaining=$kwh_remaining\n" if is_debug();

	# --- Determine if meter is closed ---
	my $is_closed = ($valve_status eq 'close' || $kwh_remaining <= 0);
	warn "[DEBUG] Meter closed=$is_closed\n" if is_debug();

	# --- Calculate time_remaining_hours ---
	my $time_remaining_hours;
	if ($sw_version =~ /NO_AUTO_CLOSE/) {
		$time_remaining_hours = undef;
		warn "[DEBUG] SW version NO_AUTO_CLOSE => time_remaining_hours=∞\n" if is_debug();
	} elsif ($is_closed) {
		$time_remaining_hours = 0;
		warn "[DEBUG] Valve closed or no kWh remaining => time_remaining_hours=0\n" if is_debug();
	} elsif ($avg_energy_last_day > 0) {
		$time_remaining_hours = $kwh_remaining / $avg_energy_last_day;
		warn "[DEBUG] Calculated time_remaining_hours=$time_remaining_hours\n" if is_debug();
	} else {
		$time_remaining_hours = undef;
		warn "[DEBUG] avg_energy_last_day=0 => time_remaining_hours=∞\n" if is_debug();
	}

	# --- Human-readable string ---
	my $time_remaining_hours_string = (!defined $time_remaining_hours || $valve_installed == 0)
		? '∞'
		: rounded_duration($time_remaining_hours * 3600);
	warn "[DEBUG] Time remaining string=$time_remaining_hours_string\n" if is_debug();

	# --- Final summary ---
	warn "[DEBUG] Summary: latest_energy=$latest_energy, prev_energy=$prev_energy, kwh_remaining=$kwh_remaining, time_remaining_hours_string=$time_remaining_hours_string\n" if is_debug();

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
