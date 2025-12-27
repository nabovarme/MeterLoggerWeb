package Nabovarme::Utils;

use strict;
use warnings;
use utf8;
use Exporter 'import';
use POSIX qw(floor);
use File::Basename;

our @EXPORT = qw(
	rounded_duration
	estimate_remaining_energy
	log_info
	log_warn
	log_debug
	log_die
);

$| = 1;  # Autoflush STDOUT

# Make sure STDOUT and STDERR handles UTF-8
binmode(STDOUT, ":utf8");
binmode(STDERR, ":utf8");

# Get the basename of the script, without path or .pl extension
my $script_name = basename($0, ".pl");

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

	log_debug("$serial: Latest sample fetched: latest_energy=" . sprintf("%.2f", $latest_energy) .
		", valve_status=" . $valve_status .
		", valve_installed=" . $valve_installed .
		", sw_version=" . $sw_version);

	# --- Fetch meter setup_value ---
	$sth = $dbh->prepare(qq[
		SELECT setup_value
		FROM meters
		WHERE serial = $quoted_serial
	]);
	$sth->execute;
	($setup_value) = $sth->fetchrow_array;
	$setup_value ||= 0;
	log_debug("$serial: Setup value=" . sprintf("%.2f", $setup_value));

	# --- Fetch paid kWh from accounts ---
	$sth = $dbh->prepare(qq[
		SELECT SUM(amount / price)
		FROM accounts
		WHERE serial = $quoted_serial
	]);
	$sth->execute;
	($paid_kwh) = $sth->fetchrow_array;
	$paid_kwh ||= 0;
	log_debug("$serial: Paid kWh=" . sprintf("%.2f", $paid_kwh));

	# ============================================================
	# yearly historical: historical multi-year / partial average
	# ============================================================

	# Use current paid_kwh as energy to consume
	log_debug("$serial: yearly historical: energy_available set to paid_kwh=" . sprintf("%.2f", $paid_kwh));

	# Determine how many full years of data exist for this meter
	my ($earliest_unix_time) = $dbh->selectrow_array(qq[
		SELECT MIN(unix_time)
		FROM samples_daily
		WHERE serial = $quoted_serial
	]);

	my $years_back = 0;
	if (defined $earliest_unix_time) {
		my $earliest_year = (localtime($earliest_unix_time))[5] + 1900;
		my $current_year  = (localtime(time()))[5] + 1900;
		$years_back = $current_year - $earliest_year;
		log_debug("$serial: Earliest sample year=$earliest_year, current year=$current_year, years_back=$years_back");
	} else {
		log_debug("$serial: No earliest sample found, years_back=0");
	}

	my @durations_sec;
	my @avg_kwh_per_hour;

	# --- Loop over previous years to measure time to consume paid kWh ---
	for my $year_offset (1 .. $years_back) {

		# Start sample for same day-of-year in previous year
		my ($start_energy, $start_time) = $dbh->selectrow_array(qq[
			SELECT energy, unix_time
			FROM samples_daily
			WHERE serial = $quoted_serial
			  AND DAYOFYEAR(FROM_UNIXTIME(unix_time)) = DAYOFYEAR(DATE_SUB(NOW(), INTERVAL $year_offset YEAR))
			ORDER BY unix_time ASC
			LIMIT 1
		]);
		log_debug("$serial: Year offset=$year_offset, start_energy=" . (defined $start_energy ? sprintf("%.2f", $start_energy) : 'undef') .
			", start_time=" . (defined $start_time ? $start_time : 'undef'));

		next unless defined $start_energy && defined $start_time;

		# End sample: when remaining energy is consumed
		my $energy_available = $paid_kwh - ($latest_energy - $start_energy);
		$energy_available = 0 if $energy_available < 0; # prevent negative

		my $target_energy = $start_energy + $energy_available;

		my ($end_time) = $dbh->selectrow_array(qq[
			SELECT unix_time
			FROM samples_daily
			WHERE serial = $quoted_serial
			  AND energy >= $target_energy
			  AND unix_time >= $start_time
			ORDER BY unix_time ASC
			LIMIT 1
		]);
		log_debug("$serial: Year offset=$year_offset, end_time=" . (defined $end_time ? $end_time : 'undef'));

		next unless defined $end_time;

		my $duration_sec = $end_time - $start_time;
		if ($duration_sec <= 0) {
			log_debug("$serial: Year offset=$year_offset, duration_sec <= 0, skipping");
			next;
		}

		push @durations_sec, $duration_sec;

		# --- Calculate avg kWh per hour for this year ---
		my $duration_hours = $duration_sec / 3600;
		push @avg_kwh_per_hour, $duration_hours > 0 ? $energy_available / $duration_hours : 0;
		log_debug("$serial: Year offset=$year_offset, avg_kwh_hour=" . sprintf("%.2f", $avg_kwh_per_hour[-1]));
	}

	# --- Compute overall average kWh per hour from previous years ---
	if (@avg_kwh_per_hour) {
		my $sum_kwh_hour = 0;
		$sum_kwh_hour += $_ for @avg_kwh_per_hour;
		my $avg_energy_last_day = $sum_kwh_hour / @avg_kwh_per_hour;

		my $avg_duration_sec     = 0;
		$avg_duration_sec += $_ for @durations_sec;
		$avg_duration_sec /= @durations_sec if @durations_sec;

		my $time_remaining_hours = $avg_duration_sec / 3600;

		# Set energy_last_day to avg_energy_last_day for this method
		my $energy_last_day = $avg_energy_last_day;

		log_debug("$serial: yearly historical: avg_energy_last_day=" . sprintf("%.2f", $avg_energy_last_day) .
			", energy_last_day=" . sprintf("%.2f", $energy_last_day) .
			", time_remaining_hours=" . sprintf("%.2f", $time_remaining_hours)
		);

		return {
			time_remaining_hours => sprintf('%.2f', $time_remaining_hours),
			avg_energy_last_day  => sprintf('%.2f', $avg_energy_last_day),
			energy_last_day      => sprintf('%.2f', $energy_last_day),
		};
	}

	log_debug("$serial: yearly historical not usable, falling back to existing logic");

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
	log_debug("$serial: Has historical data? " . ($has_historical_data ? "Yes" : "No"));

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
	$prev_unix_time     = $latest_unix_time unless defined $prev_unix_time;

	log_debug("$serial: Sample at start of period: " . $prev_unix_time . " => " . sprintf("%.2f", $prev_energy_sample) . " kWh");
	log_debug("$serial: Sample at end of period:   " . $latest_unix_time . " => " . sprintf("%.2f", $latest_energy) . " kWh");

	# --- Decide if we should use fallback or real samples ---
	my $prev_kwh_remaining = $setup_value + $paid_kwh - $prev_energy_sample;
	my $current_kwh_remaining = $setup_value + $paid_kwh - $latest_energy;

	my $use_fallback = 0;
	if (!defined $prev_energy_sample) {
		$use_fallback = 1;
		log_debug("$serial: No previous sample => using fallback");
	}
	elsif ($latest_energy < $prev_energy_sample) {
		log_debug("$serial: kWh decreased (meter reset/opened) => using fallback");
		$use_fallback = 1;
	}
	elsif ($current_kwh_remaining > $prev_kwh_remaining) {
		log_debug("$serial: kWh_remaining increased (meter opened/reset) => using fallback");
		$use_fallback = 1;
	}
	elsif ($prev_unix_time && (time() - $prev_unix_time < 12*3600) && $has_historical_data) {
		log_debug("$serial: Previous sample less than 12 hours old and historical data exists => using fallback");
		$use_fallback = 1;
	}
	else {
		log_debug("$serial: Using available samples for estimation");
	}

	$prev_energy = $use_fallback ? 0 : $prev_energy_sample;
	log_debug("$serial: Previous energy used=" . sprintf("%.2f", $prev_energy));

	# --- Calculate energy last day and avg energy last day ---
	my ($energy_last_day, $avg_energy_last_day);

	if (!$use_fallback) {
		# Calculate energy consumed since previous sample
		$energy_last_day = $latest_energy - $prev_energy;

		# Calculate hours between previous and latest sample
		my $hours_diff = ($latest_unix_time - $prev_unix_time) / 3600;

		# Protect against division by zero or very small intervals
		if ($hours_diff <= 0) {
			$avg_energy_last_day = 0;
			log_debug("$serial: Hours difference <= 0, setting avg_energy_last_day=0");
		}
		else {
			$avg_energy_last_day = $energy_last_day / $hours_diff;
			log_debug("$serial: Calculated avg_energy_last_day using actual hours_diff=$hours_diff, avg_energy_last_day=" . sprintf("%.2f", $avg_energy_last_day));
		}
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

		log_debug("$serial: Fallback: avg_daily_usage=" . sprintf("%.2f", $avg_daily_usage) . " from " . $years_count . " previous years");

		$energy_last_day     = $avg_daily_usage;
		$avg_energy_last_day = $avg_daily_usage;

		log_debug("$serial: Using fallback from samples_daily.effect, energy_last_day=" . sprintf("%.2f", $avg_daily_usage) .
			", avg_energy_last_day=" . sprintf("%.2f", $avg_daily_usage));
	}
	log_debug("$serial: Energy last day=" . sprintf("%.2f", $energy_last_day) .
		", avg_energy_last_day=" . sprintf("%.2f", $avg_energy_last_day));

	# --- Calculate kWh remaining ---
	my $kwh_remaining = $paid_kwh - $latest_energy + $setup_value;
	log_debug("$serial: kWh remaining=" . sprintf("%.2f", $kwh_remaining));

	# --- Determine if meter is closed ---
	my $is_closed = ($valve_status eq 'close' || $kwh_remaining <= 0) ? 1 : 0;
	log_debug("$serial: Meter closed=" . $is_closed);

	# --- Calculate time_remaining_hours ---
	my $time_remaining_hours;
	if ($sw_version =~ /NO_AUTO_CLOSE/) {
		$time_remaining_hours = undef;
		log_debug("$serial: SW version NO_AUTO_CLOSE => time_remaining_hours=∞");
	}
	elsif ($is_closed) {
		$time_remaining_hours = 0;
		log_debug("$serial: Valve closed or no kWh remaining => time_remaining_hours=0.00");
	}
	elsif ($avg_energy_last_day > 0) {
		$time_remaining_hours = $kwh_remaining / $avg_energy_last_day;
		log_debug("$serial: Calculated time_remaining_hours=" . sprintf("%.2f", $time_remaining_hours));
	}
	else {
		$time_remaining_hours = undef;
		log_debug("$serial: avg_energy_last_day=0 => time_remaining_hours=∞");
	}

	# --- Human-readable string ---
	my $time_remaining_hours_string = (!defined $time_remaining_hours || $valve_installed == 0)
		? '∞'
		: rounded_duration($time_remaining_hours * 3600);
	log_debug("$serial: Time remaining string=" . $time_remaining_hours_string);

	# --- Final summary ---
	log_debug("$serial: Summary: latest_energy=" . sprintf("%.2f", $latest_energy) .
		", prev_energy=" . sprintf("%.2f", $prev_energy) .
		", kwh_remaining=" . sprintf("%.2f", $kwh_remaining) .
		", time_remaining_hours_string=" . $time_remaining_hours_string);

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
# Logging functions
# ----------------------------
sub log_info {
	my (@msgs) = @_;
	my $opts = {};
	if (ref $msgs[-1] eq 'HASH') {
		$opts = pop @msgs;
	}
	_log_message(\*STDOUT, '', \@msgs, $opts);
}

sub log_warn {
	my (@msgs) = @_;
	my $opts = {};
	if (ref $msgs[-1] eq 'HASH') {
		$opts = pop @msgs;
	}
	_log_message(\*STDERR, 'WARN', \@msgs, $opts);
}

sub log_debug {
	return unless ($ENV{ENABLE_DEBUG} // '') =~ /^(1|true|yes)$/i;
	my (@msgs) = @_;
	my $opts = {};
	if (ref $msgs[-1] eq 'HASH') {
		$opts = pop @msgs;
	}
	_log_message(\*STDOUT, 'DEBUG', \@msgs, $opts);
}

sub log_die {
	my (@msgs) = @_;
	my $opts = {};
	if (ref $msgs[-1] eq 'HASH') {
		$opts = pop @msgs;
	}

	# Log as WARN first
	_log_message(\*STDERR, 'WARN', \@msgs, $opts);

	# Exit immediately with joined messages
	my $text = join('', map { defined $_ ? $_ : '' } @msgs);
	chomp($text);
	die "[" . ($opts->{no_script_name} ? '' : $script_name) . "] [WARN] $text\n";
}

sub _log_message {
	my ($fh, $level, $msgs_ref, $opts) = @_;

	my $disable_tag        = $opts->{-no_tag};
	my $disable_script     = $opts->{-no_script_name};
	my $custom_tag         = $opts->{-custom_tag};          # e.g. "SMS"
	my $custom_script_name = $opts->{-custom_script_name};  # e.g. "my_script.pl"

	# Determine caller info
	my ($caller_package, $caller_file, $caller_line) = caller(1);  # caller of log_* function
	my $module_name = ($caller_package && $caller_package ne 'main') ? $caller_package : undef;

	my $script_display = $disable_script ? '' : ($custom_script_name || $script_name);

	# Determine prefix for levels like WARN/DEBUG
	my $prefix = (!$disable_tag && $level) ? "[$level] " : '';

	foreach my $msg (@$msgs_ref) {
		my $text = defined $msg ? $msg : '';
		chomp($text);

		# Determine output style
		my $line;
		if (defined $custom_tag) {
			# Custom tag is always separate brackets
			my @parts;
			push @parts, "[$script_display]" if $script_display;
			push @parts, "[$custom_tag]";
			my $line_prefix = join(' ', @parts);
			$line = "$line_prefix $prefix$text";
		} elsif ($module_name && $caller_package eq $module_name && !$disable_script) {
			# Called from another function in the same module → arrow style
			$line = "[$script_display->$module_name] $prefix$text";
		} elsif ($module_name && !$disable_script) {
			# External module → separate brackets
			$line = "[$script_display] [$module_name] $prefix$text";
		} elsif ($module_name) {
			$line = "[$module_name] $prefix$text";
		} elsif (!$disable_script) {
			$line = "[$script_display] $prefix$text";
		} else {
			$line = "$prefix$text";
		}

		print $fh "$line\n";
	}
}


1;

__END__
