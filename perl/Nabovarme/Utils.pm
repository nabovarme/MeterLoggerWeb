package Nabovarme::Utils;

use strict;
use warnings;
use utf8;
use Exporter 'import';
use POSIX qw(floor);
use File::Basename;

our @EXPORT = qw(rounded_duration estimate_remaining_energy);

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

	my $latest_energy_fmt = sprintf("%.2f", $latest_energy);

	debug_print("[DEBUG] ",
		"Latest sample fetched: latest_energy=", $latest_energy_fmt,
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
	$prev_energy_sample ||= 0;

	# --- Fetch meter setup_value ---
	$sth = $dbh->prepare(qq[
		SELECT setup_value
		FROM meters
		WHERE serial = $quoted_serial
	]);
	$sth->execute;
	($setup_value) = $sth->fetchrow_array;
	$setup_value ||= 0;

	my $setup_value_fmt = sprintf("%.2f", $setup_value);
	debug_print("[DEBUG] ", "Setup value=", $setup_value_fmt);

	# --- Fetch paid kWh from accounts ---
	$sth = $dbh->prepare(qq[
		SELECT SUM(amount / price)
		FROM accounts
		WHERE serial = $quoted_serial
	]);
	$sth->execute;
	($paid_kwh) = $sth->fetchrow_array;
	$paid_kwh ||= 0;

	my $paid_kwh_fmt = sprintf("%.2f", $paid_kwh);
	debug_print("[DEBUG] ", "Paid kWh=", $paid_kwh_fmt);

	# --- Determine if we can use the last day's sample ---
	my $prev_kwh_remaining = $setup_value + $paid_kwh - $prev_energy_sample;
	my $current_kwh_remaining = $setup_value + $paid_kwh - $latest_energy;

	my $use_fallback = 0;
	if ($prev_energy_sample == $latest_energy) {
		debug_print("[DEBUG] ", "latest_energy == prev_energy (", $latest_energy_fmt, ") => using fallback");
		$use_fallback = 1;
	}
	elsif ($prev_unix_time && (time() - $prev_unix_time) < 12*3600) {
		debug_print("[DEBUG] ", "Previous sample less than 12 hours old => using fallback");
		$use_fallback = 1;
	}
	elsif ($current_kwh_remaining > $prev_kwh_remaining) {
		debug_print("[DEBUG] ", "kwh_remaining increased (meter opened/reset) => using fallback");
		$use_fallback = 1;
	}

	$prev_energy = $use_fallback ? 0 : $prev_energy_sample;
	my $prev_energy_fmt = sprintf("%.2f", $prev_energy);
	debug_print("[DEBUG] ", "Previous energy used=", $prev_energy_fmt);

	# --- Calculate energy last day and avg energy last day ---
	my ($energy_last_day, $avg_energy_last_day);

	if (!$use_fallback && $prev_energy) {
		$energy_last_day     = $latest_energy - $prev_energy;
		$avg_energy_last_day = $energy_last_day / 24;

		my $avg_energy_last_day_fmt = sprintf("%.2f", $avg_energy_last_day);
		debug_print("[DEBUG] ", "Using normal 24h average for avg_energy_last_day=", $avg_energy_last_day_fmt);
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

		my $avg_daily_usage_fmt = sprintf("%.2f", $avg_daily_usage);
		debug_print("[DEBUG] ", "Fallback: avg_daily_usage=", $avg_daily_usage_fmt, " from ", $years_count, " previous years");

		$energy_last_day     = $avg_daily_usage;
		$avg_energy_last_day = $avg_daily_usage;

		debug_print("[DEBUG] ",
			"Using fallback from samples_daily.effect, energy_last_day=", $avg_daily_usage_fmt,
			", avg_energy_last_day=", $avg_daily_usage_fmt);
	}

	my $energy_last_day_fmt     = sprintf("%.2f", $energy_last_day);
	my $avg_energy_last_day_fmt = sprintf("%.2f", $avg_energy_last_day);

	debug_print("[DEBUG] ",
		"Energy last day=", $energy_last_day_fmt,
		", avg_energy_last_day=", $avg_energy_last_day_fmt);

	# --- Calculate kWh remaining ---
	my $kwh_remaining = $paid_kwh - $latest_energy + $setup_value;
	my $kwh_remaining_fmt = sprintf("%.2f", $kwh_remaining);

	debug_print("[DEBUG] ", "kWh remaining=", $kwh_remaining_fmt);

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
		my $time_remaining_hours_fmt = sprintf("%.2f", $time_remaining_hours);
		debug_print("[DEBUG] ", "Calculated time_remaining_hours=", $time_remaining_hours_fmt);
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
	debug_print("[DEBUG] ",
		"Summary: latest_energy=", $latest_energy_fmt,
		", prev_energy=", $prev_energy_fmt,
		", kwh_remaining=", $kwh_remaining_fmt,
		", time_remaining_hours_string=", $time_remaining_hours_string);

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

# ----------------------------
# Debug print helper
# ----------------------------
sub debug_print {
	# Only print if debug mode is enabled via environment variable
	return unless ($ENV{ENABLE_DEBUG} // '') =~ /^(1|true)$/i;

	# Make sure STDERR handles UTF-8
	binmode STDERR, ":encoding(UTF-8)";

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
