package Nabovarme::Utils;

use strict;
use warnings;
use utf8;
use Exporter 'import';
use POSIX qw(floor);
use File::Basename;

our @EXPORT = qw(rounded_duration estimate_remaining_energy);

# Make sure STDOUT and STDERR handles UTF-8
binmode(STDOUT, ":utf8");
binmode(STDERR, ":utf8");

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

	my ($latest_energy, $latest_unix_time, $prev_energy, $setup_value, $paid_kwh, $valve_status, $valve_installed, $sw_version);

	# --- Fetch latest sample and valve_status ---
	my $sth = $dbh->prepare(qq[
		SELECT sc.energy, sc.unix_time, m.valve_status, m.valve_installed, m.sw_version
		FROM meters m
		LEFT JOIN samples_cache sc ON m.serial = sc.serial
		WHERE m.serial = $quoted_serial
		ORDER BY sc.unix_time DESC
		LIMIT 1
	]);
	$sth->execute;
	($latest_energy, $latest_unix_time, $valve_status, $valve_installed, $sw_version) = $sth->fetchrow_array;
	$latest_energy   = 0 unless defined $latest_energy;
	$latest_unix_time = time() unless defined $latest_unix_time; # fallback
	$valve_status    ||= '';
	$valve_installed ||= 0;
	$sw_version      ||= '';

	debug_print("[DEBUG] ",
		"Latest sample fetched: latest_energy=", sprintf("%.2f", $latest_energy),
		", valve_status=", $valve_status,
		", valve_installed=", $valve_installed,
		", sw_version=", $sw_version);

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

	# --- Determine if we have historical daily samples ---
	my $has_historical_data = 0;
	$sth = $dbh->prepare(qq[
		SELECT COUNT(*)
		FROM samples_daily
		WHERE serial = $quoted_serial
		  AND YEAR(FROM_UNIXTIME(unix_time)) < YEAR(NOW())
	]);
	$sth->execute;
	my ($historical_count) = $sth->fetchrow_array;
	$has_historical_data = $historical_count > 0 ? 1 : 0;
	debug_print("[DEBUG] ", "Has historical data? ", $has_historical_data ? "Yes" : "No");

	# --- Fallback to oldest sample if no historical data ---
	if ((!defined $prev_energy_sample || !defined $prev_unix_time) && !$has_historical_data) {
		$sth = $dbh->prepare(qq[
			SELECT energy, `unix_time`
			FROM samples_cache
			WHERE serial = $quoted_serial
			ORDER BY `unix_time` ASC
			LIMIT 1
		]);
		$sth->execute;
		($prev_energy_sample, $prev_unix_time) = $sth->fetchrow_array;
	}

	$prev_energy_sample = 0 unless defined $prev_energy_sample;
	$prev_unix_time     = $latest_unix_time unless defined $prev_unix_time;  # fallback to latest if still undefined

	debug_print("[DEBUG] Serial: $serial\n");
	debug_print("[DEBUG] Sample at start of period: ", $prev_unix_time, " => ", sprintf("%.2f", $prev_energy_sample), " kWh\n");
	debug_print("[DEBUG] Sample at end of period:   ", $latest_unix_time, " => ", sprintf("%.2f", $latest_energy), " kWh\n");

	# --- Fetch meter setup_value ---
	$sth = $dbh->prepare(qq[
		SELECT setup_value
		FROM meters
		WHERE serial = $quoted_serial
	]);
	$sth->execute;
	($setup_value) = $sth->fetchrow_array;
	$setup_value ||= 0;
	debug_print("[DEBUG] ", "Setup value=", sprintf("%.2f", $setup_value));

	# --- Fetch paid kWh from accounts ---
	$sth = $dbh->prepare(qq[
		SELECT SUM(amount / price)
		FROM accounts
		WHERE serial = $quoted_serial
	]);
	$sth->execute;
	($paid_kwh) = $sth->fetchrow_array;
	$paid_kwh ||= 0;
	debug_print("[DEBUG] ", "Paid kWh=", sprintf("%.2f", $paid_kwh));

	# --- Decide if we should use fallback or real samples ---
	my $prev_kwh_remaining = $setup_value + $paid_kwh - $prev_energy_sample;
	my $current_kwh_remaining = $setup_value + $paid_kwh - $latest_energy;

	my $use_fallback = 0;
	if (!defined $prev_energy_sample) {
		$use_fallback = 1;
		debug_print("[DEBUG] ", "No previous sample => using fallback");
	}
	elsif ($latest_energy < $prev_energy_sample) {
		debug_print("[DEBUG] ", "kWh decreased (meter reset/opened) => using fallback");
		$use_fallback = 1;
	}
	elsif ($current_kwh_remaining > $prev_kwh_remaining) {
		debug_print("[DEBUG] ", "kwh_remaining increased (meter opened/reset) => using fallback");
		$use_fallback = 1;
	}
	# Only enforce 12-hour rule if historical data exists
	elsif ($prev_unix_time && (time() - $prev_unix_time < 12*3600) && $has_historical_data) {
		debug_print("[DEBUG] ", "Previous sample less than 12 hours old and historical data exists => using fallback");
		$use_fallback = 1;
	}
	else {
		debug_print("[DEBUG] ", "Using available samples for estimation");
	}

	$prev_energy = $use_fallback ? 0 : $prev_energy_sample;
	debug_print("[DEBUG] ", "Previous energy used=", sprintf("%.2f", $prev_energy));

	# --- Calculate energy last day and avg energy last day ---
	my ($energy_last_day, $avg_energy_last_day);

	if (!$use_fallback) {
		$energy_last_day     = $latest_energy - $prev_energy;
		$avg_energy_last_day = $energy_last_day / 24;
		debug_print("[DEBUG] ", "Using actual 24h average for avg_energy_last_day=", sprintf("%.2f", $avg_energy_last_day));
	}
	else {
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

		debug_print("[DEBUG] ", "Fallback: avg_daily_usage=", sprintf("%.2f", $avg_daily_usage), " from ", $years_count, " previous years");

		$energy_last_day     = $avg_daily_usage;
		$avg_energy_last_day = $avg_daily_usage;

		debug_print("[DEBUG] ",
			"Using fallback from samples_daily.effect, energy_last_day=", sprintf("%.2f", $avg_daily_usage),
			", avg_energy_last_day=", sprintf("%.2f", $avg_daily_usage));
	}
	debug_print("[DEBUG] ",
		"Energy last day=", sprintf("%.2f", $energy_last_day),
		", avg_energy_last_day=", sprintf("%.2f", $avg_energy_last_day));

	# --- Calculate kWh remaining ---
	my $kwh_remaining = $paid_kwh - $latest_energy + $setup_value;
	debug_print("[DEBUG] ", "kWh remaining=", sprintf("%.2f", $kwh_remaining));

	# --- Determine if meter is closed ---
	my $is_closed = ($valve_status eq 'close' || $kwh_remaining <= 0);
	debug_print("[DEBUG] ", "Meter closed=", $is_closed);

	# --- Calculate time_remaining_hours ---
	my $time_remaining_hours;
	if ($sw_version =~ /NO_AUTO_CLOSE/) {
		$time_remaining_hours = undef;
		debug_print("[DEBUG] ", "SW version NO_AUTO_CLOSE => time_remaining_hours=∞");
	}
	elsif ($is_closed) {
		$time_remaining_hours = 0;
		debug_print("[DEBUG] ", "Valve closed or no kWh remaining => time_remaining_hours=0.00");
	}
	elsif ($avg_energy_last_day > 0) {
		$time_remaining_hours = $kwh_remaining / $avg_energy_last_day;
		debug_print("[DEBUG] ", "Calculated time_remaining_hours=", sprintf("%.2f", $time_remaining_hours));
	}
	else {
		$time_remaining_hours = undef;
		debug_print("[DEBUG] ", "avg_energy_last_day=0 => time_remaining_hours=∞");
	}

	# --- Human-readable string ---
	my $time_remaining_hours_string = (!defined $time_remaining_hours || $valve_installed == 0)
		? '∞'
		: rounded_duration($time_remaining_hours * 3600);
	debug_print("[DEBUG] ", "Time remaining string=", $time_remaining_hours_string);

	# --- Final summary ---
	debug_print("[DEBUG] ", "Summary: latest_energy=", sprintf("%.2f", $latest_energy),
		", prev_energy=", sprintf("%.2f", $prev_energy),
		", kwh_remaining=", sprintf("%.2f", $kwh_remaining),
		", time_remaining_hours_string=", $time_remaining_hours_string);

	# --- Format numbers for return ---
	return {
		kwh_remaining               => sprintf("%.2f", $kwh_remaining),
		time_remaining_hours        => defined $time_remaining_hours ? sprintf("%.2f", $time_remaining_hours) : undef,
		time_remaining_hours_string => $time_remaining_hours_string,
		energy_last_day             => sprintf("%.2f", $energy_last_day),
		avg_energy_last_day         => sprintf("%.2f", $avg_energy_last_day),
		latest_energy               => sprintf("%.2f", $latest_energy),
		paid_kwh                    => sprintf("%.2f", $paid_kwh),
		setup_value                 => sprintf("%.2f", $setup_value),
		valve_status                => $valve_status,
		valve_installed             => $valve_installed,
	};
}

# ----------------------------
# Debug print helper
# ----------------------------
sub debug_print {
	# Only print if debug mode is enabled via environment variable
	return;
	return unless ($ENV{ENABLE_DEBUG} // '') =~ /^(1|true)$/i;

	# Get the basename of the script, without path or .pl extension
	my $script_name = basename($0, ".pl");

	# Get module/package name (optional: set it manually or dynamically)
	my $module_name = __PACKAGE__;

	# Prepare the output string, converting undef to empty string
	my $output = join('', map { defined $_ ? $_ : '' } @_);

	# Print the script and module name prefix plus the output to STDERR
	print STDERR "[", $script_name, "->", $module_name, "] ", $output;

	# Only add a newline if the output doesn't already end with one
	print STDERR "\n" unless $output =~ /\n\z/;
}

1;
