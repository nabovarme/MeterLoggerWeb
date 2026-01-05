package Nabovarme::EnergyEstimator;

use strict;
use warnings;
use utf8;
use Exporter 'import';
use POSIX qw(floor);

use Nabovarme::Utils;

our @EXPORT = qw(
	estimate_remaining_energy
);

$| = 1;  # Autoflush STDOUT

# Make sure STDOUT and STDERR handles UTF-8
binmode(STDOUT, ":encoding(UTF-8)");
binmode(STDERR, ":encoding(UTF-8)");

# Minimum kWh/h to identify zero/closed years or closed valves
use constant MIN_VALID_KWH_PER_HOUR => 0.05;

sub estimate_remaining_energy {
	my ($dbh, $serial) = @_;

	# --- Initialize result hash with defaults ---
	my %result = (
		kwh_remaining               => undef,
		time_remaining_hours        => undef,
		time_remaining_hours_string => '∞',
		energy_last_day             => 0,
		avg_energy_last_day         => 0,
		latest_energy               => 0,
		paid_kwh                    => 0,
		setup_value                 => 0,
		valve_status                => '',
		valve_installed             => 0,
		sw_version                  => '',
		method                      => undef,
		close_notification_time     => 604800,
		notification_state          => 0,
		last_notification_sent_time => undef,
		last_paid_kwh_marker        => undef,
	);

	# Early return if missing DB handle or serial
	return \%result unless $dbh && $serial;

	my $quoted_serial = $dbh->quote($serial);

	# ============================================================
	# --- ALWAYS fetch notification/state fields from DB ---
	# ============================================================
	my $sth_state = $dbh->prepare(qq[
		SELECT notification_state,
			last_notification_sent_time,
			last_paid_kwh_marker,
			close_notification_time,
			paid_kwh
		FROM meters_state
		WHERE serial = $quoted_serial
		LIMIT 1
	]) or log_die("Failed to prepare statement for meters_state state fields: $DBI::errstr");

	$sth_state->execute() or log_die("Failed to execute statement for meters_state state fields: $DBI::errstr");

	my ($notification_state, $last_notification_sent_time, $last_paid_kwh_marker, $close_notification_time, $paid_kwh) =
	    $sth_state->fetchrow_array;

	# Populate result hash (overwrite defaults if DB has values)
	$result{notification_state}          = $notification_state          if defined $notification_state;
	$result{last_notification_sent_time} = $last_notification_sent_time if defined $last_notification_sent_time;
	$result{last_paid_kwh_marker}        = $last_paid_kwh_marker        if defined $last_paid_kwh_marker;
	$result{close_notification_time}     = $close_notification_time     if defined $close_notification_time;
	$result{paid_kwh}                    = $paid_kwh                    if defined $paid_kwh;

	# --- Check cached values (recalculate if older than 1 min) ---
	my $sth = $dbh->prepare(qq[
		SELECT kwh_remaining,
			time_remaining_hours,
			time_remaining_hours_string,
			energy_last_day,
			avg_energy_last_day,
			latest_energy,
			paid_kwh,
			method,
			close_notification_time,
			notification_state,
			last_notification_sent_time,
			last_paid_kwh_marker,
			UNIX_TIMESTAMP(last_updated) AS last_updated
		FROM meters_state
		WHERE serial = $quoted_serial
		LIMIT 1
	]) or log_die("Failed to prepare statement for cached meters_state: $DBI::errstr");

	$sth->execute() or log_die("Failed to execute statement for cached meters_state: $DBI::errstr");

	my ($cached) = $sth->fetchrow_hashref;

	if ($cached) {
		# Always populate state fields (overwrite defaults if present in cache)
		$result{last_paid_kwh_marker}        = $cached->{last_paid_kwh_marker}        if defined $cached->{last_paid_kwh_marker};
		$result{last_notification_sent_time} = $cached->{last_notification_sent_time} if defined $cached->{last_notification_sent_time};
		$result{notification_state}          = $cached->{notification_state}          if defined $cached->{notification_state};
		$result{close_notification_time}     = $cached->{close_notification_time}     if defined $cached->{close_notification_time};
		
		# Only return early if cache is fresh
		my $age_sec = time() - ($cached->{last_updated} // 0);
		if ($age_sec < 60 && defined $cached->{kwh_remaining}) {
			# cached < 1 min old AND valid
			log_debug("$serial: Using cached meters_state (age $age_sec sec, kwh_remaining=$cached->{kwh_remaining})");
			%result = (
				%result,  # keep state fields
				kwh_remaining               => $cached->{kwh_remaining},
				time_remaining_hours        => $cached->{time_remaining_hours},
				time_remaining_hours_string => $cached->{time_remaining_hours_string},
				energy_last_day             => $cached->{energy_last_day},
				avg_energy_last_day         => $cached->{avg_energy_last_day},
				latest_energy               => $cached->{latest_energy},
				paid_kwh                    => $cached->{paid_kwh},
				method                      => $cached->{method},
			);
			return \%result;
		}
	}

	# ============================================================
	# --- Fetch latest sample and valve_status ---
	# ============================================================
	my ($latest_energy, $latest_unix_time, $valve_status, $valve_installed, $sw_version);

	$sth = $dbh->prepare(qq[
		SELECT sc.energy, sc.unix_time, m.valve_status, m.valve_installed, m.sw_version
		FROM meters m
		LEFT JOIN samples_cache sc ON m.serial = sc.serial
		WHERE m.serial = $quoted_serial
		ORDER BY sc.unix_time DESC
		LIMIT 1
	]) or log_die("Failed to prepare statement for latest sample: $DBI::errstr");
	$sth->execute() or log_die("Failed to execute statement for latest sample: $DBI::errstr");

	($latest_energy, $latest_unix_time, $valve_status, $valve_installed, $sw_version) = $sth->fetchrow_array;

	$latest_energy    = 0 unless defined $latest_energy;
	$latest_unix_time = time() unless defined $latest_unix_time;
	$valve_status     ||= '';
	$valve_installed  ||= 0;
	$sw_version       ||= '';

	log_debug("$serial: Latest sample fetched: latest_energy=" . sprintf("%.2f", $latest_energy) .
		", valve_status=" . $valve_status .
		", valve_installed=" . $valve_installed .
		", sw_version=" . $sw_version);

	# --- Fetch meter setup_value ---
	$sth = $dbh->prepare(qq[
		SELECT setup_value
		FROM meters
		WHERE serial = $quoted_serial
	]) or log_die("$serial: Failed to prepare statement for setup_value: $DBI::errstr");
	$sth->execute() or log_die("$serial: Failed to execute statement for setup_value: $DBI::errstr");
	my $setup_value = $sth->fetchrow_array;
	$setup_value ||= 0;

	# --- Fetch paid kWh from accounts ---
	$sth = $dbh->prepare(qq[
		SELECT SUM(amount / price)
		FROM accounts
		WHERE serial = $quoted_serial
	]) or log_die("$serial: Failed to prepare statement for paid_kwh: $DBI::errstr");
	$sth->execute() or log_die("$serial: Failed to execute statement for paid_kwh: $DBI::errstr");
	my $paid_kwh = $sth->fetchrow_array;
	$paid_kwh ||= 0;

	# --- Populate basic results ---
	$result{latest_energy}   = $latest_energy;
	$result{valve_status}    = $valve_status;
	$result{valve_installed} = $valve_installed;
	$result{setup_value}     = $setup_value;
	$result{paid_kwh}        = $paid_kwh;
	$result{sw_version}      = $sw_version;

	log_debug("$serial: Setup value=" . sprintf("%.2f", $setup_value));
	log_debug("$serial: Paid kWh=" . sprintf("%.2f", $paid_kwh));

	# ============================================================
	# --- Try estimation methods in order using unified interface ---
	# ============================================================

	my $res;

	# Method 1: yearly historical
	$res = estimate_from_yearly_history($dbh, $serial, $latest_energy, $setup_value, $paid_kwh);
	if (defined $res) {
		$result{method} = 'yearly_historical';
		log_debug("$serial: Yearly history returned: energy_last_day=" . sprintf("%.2f", $res->{energy_last_day}) .
			", avg_energy_last_day=" . sprintf("%.2f", $res->{avg_energy_last_day}));
	} else {
		log_debug("$serial: Yearly history returned undef");
	}

	# Method 2: recent samples
	unless (defined $res) {
		$res = estimate_from_recent_samples($dbh, $serial, $latest_energy, $setup_value, $paid_kwh, $latest_unix_time);
		if (defined $res) {
			$result{method} = 'recent_samples';
			log_debug("$serial: Recent samples returned: energy_last_day=" . sprintf("%.2f", $res->{energy_last_day}) .
				", avg_energy_last_day=" . sprintf("%.2f", $res->{avg_energy_last_day}));
		} else {
			log_debug("$serial: Recent samples returned undef");
		}
	}

	# Method 3: fallback daily
	unless (defined $res) {
		$res = estimate_from_daily_history($dbh, $serial);
		if (defined $res) {
			$result{method} = 'fallback_daily';
			log_debug("$serial: Fallback daily returned: energy_last_day=" . sprintf("%.2f", $res->{energy_last_day}) .
				", avg_energy_last_day=" . sprintf("%.2f", $res->{avg_energy_last_day}));
		} else {
			log_debug("$serial: Fallback daily returned undef");
		}
	}

	my $energy_last_day     = $res->{energy_last_day};
	my $avg_energy_last_day = $res->{avg_energy_last_day};

	log_debug("$serial: Energy last day=" . (defined $energy_last_day ? sprintf("%.2f", $energy_last_day) : 'undef') .
		", avg_energy_last_day=" . (defined $avg_energy_last_day ? sprintf("%.2f", $avg_energy_last_day) : 'undef'));

	# ============================================================
	# --- Calculate remaining kWh and time ---
	# ============================================================

	my $kwh_remaining;
	if (defined $latest_energy && defined $setup_value) {
		$kwh_remaining = $paid_kwh - $latest_energy + $setup_value;
		log_debug("$serial: kWh remaining=" . sprintf("%.2f", $kwh_remaining));
	}
	else {
		$kwh_remaining = undef;
		log_debug("$serial: kWh remaining=undef");
	}

	my $is_closed = ($valve_status eq 'close') ? 1 : 0;
	log_debug("$serial: Meter closed=" . $is_closed);

	my $time_remaining_hours = undef;
	if ($avg_energy_last_day) {
		$time_remaining_hours = $kwh_remaining / $avg_energy_last_day;
		log_debug("$serial: Calculated time_remaining_hours=" . (defined $time_remaining_hours ? sprintf("%.2f", $time_remaining_hours) : 'undef'));
	}

	my $time_remaining_hours_string;
	if (defined $time_remaining_hours) {
		$time_remaining_hours_string = rounded_duration($time_remaining_hours * 3600);
	}
	else {
		$time_remaining_hours_string = '∞';
	}
	log_debug("$serial: Time remaining string=" . $time_remaining_hours_string);

	log_debug("$serial: Summary: latest_energy=" . sprintf("%.2f", $latest_energy) .
		", kwh_remaining=" . sprintf("%.2f", $kwh_remaining) .
		", time_remaining_hours_string=" . $time_remaining_hours_string);

	# ============================================================
	# --- Final formatting ---
	# ============================================================

	$result{kwh_remaining}               = $kwh_remaining;
	$result{time_remaining_hours}        = $time_remaining_hours;
	$result{time_remaining_hours_string} = $time_remaining_hours_string;
	$result{energy_last_day}             = $energy_last_day;
	$result{avg_energy_last_day}         = $avg_energy_last_day;

	# ============================================================
	# --- Update meters_state for recalculated fields only ---
	# ============================================================
	my $sql = qq[
		INSERT INTO meters_state
		(serial, kwh_remaining, time_remaining_hours, time_remaining_hours_string,
		 energy_last_day, avg_energy_last_day, latest_energy, paid_kwh, method, last_updated)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, UNIX_TIMESTAMP(NOW()))
		ON DUPLICATE KEY UPDATE
			kwh_remaining = VALUES(kwh_remaining),
			time_remaining_hours = VALUES(time_remaining_hours),
			time_remaining_hours_string = VALUES(time_remaining_hours_string),
			energy_last_day = VALUES(energy_last_day),
			avg_energy_last_day = VALUES(avg_energy_last_day),
			latest_energy = VALUES(latest_energy),
			paid_kwh = VALUES(paid_kwh),
			method = VALUES(method),
			last_updated = UNIX_TIMESTAMP(NOW())
	];

	$sth = $dbh->prepare($sql);
	$sth->execute(
		$serial,
		$result{kwh_remaining},
		$result{time_remaining_hours},
		$result{time_remaining_hours_string},
		$result{energy_last_day},
		$result{avg_energy_last_day},
		$result{latest_energy},
		$result{paid_kwh},
		$result{method}
	) or log_warn("Failed to update meters_state for $serial: $DBI::errstr");

	return \%result;
}

# ============================================================
# 1) YEARLY HISTORICAL METHOD
# Uses multi-year daily data to estimate average consumption
# Returns ($energy_last_day, $avg_energy_last_day) or (undef, undef)
# ============================================================
sub estimate_from_yearly_history {
	my ($dbh, $serial, $latest_energy, $setup_value, $paid_kwh) = @_;

	# --- Quote serial for SQL ---
	my $quoted_serial = $dbh->quote($serial);   # QUOTED SERIAL

	my @avg_kwh_per_hour;

	# --- Find earliest sample ---
	my $sth = $dbh->prepare(qq[
		SELECT MIN(unix_time)
		FROM samples_daily
		WHERE serial = $quoted_serial
	]) or log_die("$serial: Failed to prepare statement for earliest sample: $DBI::errstr");
	$sth->execute() or log_die("$serial: Failed to execute statement for earliest sample: $DBI::errstr");
	my ($earliest_unix_time) = $sth->fetchrow_array;

	unless (defined $earliest_unix_time) {
		log_debug("$serial: No earliest sample found, yearly history cannot be used");
		return undef;
	}

	# --- Determine how many years of data exist ---
	my $earliest_year = (localtime($earliest_unix_time))[5] + 1900;
	my $current_year  = (localtime(time()))[5] + 1900;
	my $years_back    = $current_year - $earliest_year;

	log_debug("$serial: Earliest sample year=$earliest_year, current year=$current_year, years_back=$years_back");

	return undef if $years_back < 1;

	# ============================================================
	# --- Compute yearly averages ---
	# ============================================================
	my @yearly_avgs;
	my $zero_years = 0;

	for my $year_offset (1 .. $years_back) {

		# --- Fetch start energy for this year offset ---
		$sth = $dbh->prepare(qq[
			SELECT energy, unix_time
			FROM samples_daily
			WHERE serial = $quoted_serial
			  AND unix_time <= UNIX_TIMESTAMP(DATE_SUB(CURDATE(), INTERVAL $year_offset YEAR))
			ORDER BY unix_time DESC
			LIMIT 1
		]) or log_die("$serial: Failed to prepare statement for start_energy for year offset $year_offset: $DBI::errstr");
		$sth->execute() or log_die("$serial: Failed to execute statement for start_energy for year offset $year_offset: $DBI::errstr");
		my ($start_energy, $start_time) = $sth->fetchrow_array;

		log_debug("$serial: Year offset=$year_offset start_energy=" . (defined $start_energy ? sprintf('%.2f', $start_energy) : 'undef') .
			", start_time=" . (defined $start_time ? $start_time : 'undef'));

		next unless defined $start_energy && defined $start_time;

		# --- Compute available energy for this year ---
		my $energy_available = $paid_kwh - ($latest_energy - $start_energy);
		$energy_available = 0 if $energy_available < 0;
		my $target_energy = $start_energy + $energy_available;

		# --- Find end time when this energy was reached ---
		$sth = $dbh->prepare(qq[
			SELECT unix_time
			FROM samples_daily
			WHERE serial = $quoted_serial
			  AND energy >= $target_energy
			  AND unix_time >= $start_time
			ORDER BY unix_time ASC
			LIMIT 1
		]) or log_die("$serial: Failed to prepare statement for end_time for year offset $year_offset: $DBI::errstr");
		$sth->execute() or log_die("$serial: Failed to execute statement for end_time for year offset $year_offset: $DBI::errstr");
		my ($end_time) = $sth->fetchrow_array;
		
		if (!defined $end_time) {
			log_debug("$serial: Year offset=$year_offset end_time=undef, skipping");
			next;
		}
		log_debug("$serial: Year offset=$year_offset end_time=$end_time");
		
		# --- Compute hourly average ---
		my $duration_sec = $end_time - $start_time;
		if ($duration_sec <= 0) {
			log_debug("$serial: Year offset=$year_offset duration_sec=$duration_sec invalid, skipping");
			next;
		}
		log_debug("$serial: Year offset=$year_offset duration_sec=$duration_sec valid");

		my $duration_hours = $duration_sec / 3600;
		my $energy_for_duration = $target_energy - $start_energy;
		my $avg_kwh_hour = $duration_hours > 0 ? $energy_for_duration / $duration_hours : 0;
		log_debug(
			"$serial: Year offset=$year_offset duration_hours=" . sprintf("%.2f", $duration_hours)
			. ", energy_for_duration=" . sprintf("%.2f", $energy_for_duration)
			. " avg_kwh_hour=" . sprintf("%.2f", $avg_kwh_hour)
		);

		# --- Skip zero/closed years ---
		if ($avg_kwh_hour < MIN_VALID_KWH_PER_HOUR) {
			$zero_years++;
			log_debug("$serial: Year offset=$year_offset avg_kwh_hour=" . sprintf("%.2f", $avg_kwh_hour) . " considered zero/closed, skipping");
			next;
		}

		push @yearly_avgs, $avg_kwh_hour;
		log_debug("$serial: Year offset=$year_offset, avg_kwh_hour=" . sprintf("%.2f", $avg_kwh_hour));
	}

	log_debug("$serial: Skipped $zero_years zero/closed years");

	unless (@yearly_avgs) {
		log_debug("$serial: No valid yearly averages remain after removing zero/closed years");
		return undef;
	}

	# ============================================================
	# --- Median + relative deviation for outlier detection ---
	# ============================================================
	my @sorted = sort { $a <=> $b } @yearly_avgs;
	my $mid = int(@sorted / 2);
	my $median = @sorted % 2 ? $sorted[$mid] : ($sorted[$mid-1] + $sorted[$mid]) / 2;

	log_debug("$serial: Median of yearly averages=$median");

	my $lower_limit = 0.7 * $median;  # 70% of median
	my $upper_limit = 1.3 * $median;  # 130% of median

	my @final_avgs;
	my $outlier_years = 0;

	for my $avg (@yearly_avgs) {
		if ($avg < $lower_limit || $avg > $upper_limit) {
			$outlier_years++;
			log_debug("$serial: avg_kwh_hour=" . sprintf("%.2f", $avg) . " is outlier, skipping");
			next;
		}
		push @final_avgs, $avg;
	}

	log_debug("$serial: Skipped $outlier_years outlier years");

	unless (@final_avgs) {
		log_debug("$serial: No valid yearly averages remain after outlier removal");
		return undef;
	}

	# --- Compute overall average across non-outlier years ---
	my $avg_energy_last_day = 0;
	$avg_energy_last_day += $_ for @final_avgs;
	$avg_energy_last_day /= @final_avgs;

	my $energy_last_day = $avg_energy_last_day;

	log_debug("$serial: Yearly historical estimate after hybrid filtering: energy_last_day=" . sprintf("%.2f", $energy_last_day) .
		", avg_energy_last_day=" . sprintf("%.2f", $avg_energy_last_day));

	return { energy_last_day => $energy_last_day, avg_energy_last_day => $avg_energy_last_day };
}

# ============================================================
# 2) RECENT SAMPLES METHOD
# Uses recent samples (~24h) with all original fallback checks
# Returns ($energy_last_day, $avg_energy_last_day) or (undef, undef)
# ============================================================
sub estimate_from_recent_samples {
	my ($dbh, $serial, $latest_energy, $setup_value, $paid_kwh, $latest_unix_time) = @_;

	# --- Quote serial for SQL ---
	my $quoted_serial = $dbh->quote($serial);   # QUOTED SERIAL

	# --- Fetch sample from ~24h ago ---
	my $sth = $dbh->prepare(qq[
		SELECT energy, `unix_time`
		FROM samples_cache
		WHERE serial = $quoted_serial
		  AND `unix_time` <= UNIX_TIMESTAMP(NOW()) - 86400
		ORDER BY `unix_time` DESC
		LIMIT 1
	]) or log_die("$serial: Failed to prepare statement for recent sample: $DBI::errstr");
	$sth->execute() or log_die("$serial: Failed to execute statement for recent sample: $DBI::errstr");
	my ($recent_energy, $recent_unix_time) = $sth->fetchrow_array;

	# --- Determine if we have historical daily samples ---
	$sth = $dbh->prepare(qq[
		SELECT COUNT(*)
		FROM samples_daily
		WHERE serial = $quoted_serial
		  AND YEAR(FROM_UNIXTIME(unix_time)) < YEAR(NOW())
	]) or log_die("$serial: Failed to prepare statement for historical count: $DBI::errstr");
	$sth->execute() or log_die("$serial: Failed to execute statement for historical count: $DBI::errstr");
	my ($historical_count) = $sth->fetchrow_array;
	my $has_historical_data = $historical_count > 0;

	log_debug("$serial: Has historical data? " . ($has_historical_data ? "Yes" : "No"));

	# --- Fallback to oldest sample if no recent sample and no historical data ---
	if ((!defined $recent_energy || !defined $recent_unix_time) && !$has_historical_data) {
		$sth = $dbh->prepare(qq[
			SELECT energy, `unix_time`
			FROM samples_cache
			WHERE serial = $quoted_serial
			ORDER BY `unix_time` ASC
			LIMIT 1
		]) or log_die("$serial: Failed to prepare statement for fallback sample: $DBI::errstr");
		$sth->execute() or log_die("$serial: Failed to execute statement for fallback sample: $DBI::errstr");
		($recent_energy, $recent_unix_time) = $sth->fetchrow_array;
	}

	$recent_energy    = 0 unless defined $recent_energy;
	$recent_unix_time = $latest_unix_time unless defined $recent_unix_time;

	log_debug("$serial: Sample at start of period: $recent_unix_time => " . sprintf("%.2f", $recent_energy) . " kWh");
	log_debug("$serial: Sample at end of period:   $latest_unix_time => " . sprintf("%.2f", $latest_energy) . " kWh");

	# --- Decide if we should use fallback or real samples ---
	my $prev_energy           = $recent_energy;
	my $prev_kwh_remaining    = $setup_value + $paid_kwh - $recent_energy;
	my $current_kwh_remaining = $setup_value + $paid_kwh - $latest_energy;

	my $use_fallback = 0;

	if (!defined $recent_energy) {
		log_debug("$serial: No previous sample => using fallback");
		$use_fallback = 1;
	}
	elsif ($latest_energy < $recent_energy) {
		log_debug("$serial: kWh decreased (meter reset/opened) => using fallback");
		$use_fallback = 1;
	}
	elsif ($current_kwh_remaining > $prev_kwh_remaining) {
		log_debug("$serial: kWh_remaining increased (meter opened/reset) => using fallback");
		$use_fallback = 1;
	}
	elsif ($recent_unix_time && (time() - $recent_unix_time < 12*3600) && $has_historical_data) {
		log_debug("$serial: Previous sample less than 12 hours old and historical data exists => using fallback");
		$use_fallback = 1;
	}
	else {
		log_debug("$serial: Using available samples for estimation");
	}

	$prev_energy = $use_fallback ? 0 : $recent_energy;
	log_debug("$serial: Previous energy used=" . sprintf("%.2f", $prev_energy));

	# --- If we need to fallback, return undef to let main function use fallback method ---
	return undef if $use_fallback;

	# --- Compute energy and average over the period ---
	my $energy_last_day = $latest_energy - $prev_energy;
	my $hours_diff      = ($latest_unix_time - $recent_unix_time) / 3600;
	if ($hours_diff <= 0) {
		log_debug("$serial: Hours difference <= 0, cannot compute average => using fallback");
		return undef;
	}

	my $avg_energy_last_day = $energy_last_day / $hours_diff;
	log_debug("$serial: Calculated avg_energy_last_day using actual hours_diff=$hours_diff, avg_energy_last_day=" . sprintf("%.2f", $avg_energy_last_day));

	return { energy_last_day => $energy_last_day, avg_energy_last_day => $avg_energy_last_day };
}

# ============================================================
# 3) FALLBACK DAILY METHOD
# Uses historical daily averages if recent samples or yearly history fail
# Returns ($energy_last_day, $avg_energy_last_day) or (undef, undef)
# ============================================================
sub estimate_from_daily_history {
	my ($dbh, $serial) = @_;

	# --- Quote serial for SQL ---
	my $quoted_serial = $dbh->quote($serial);   # QUOTED SERIAL

	# --- Fetch average daily usage from previous years for the same day ---
	my $sth = $dbh->prepare(qq[
		SELECT AVG(effect) AS avg_daily_usage, COUNT(*) AS years_count
		FROM samples_daily
		WHERE serial = $quoted_serial
		  AND DAYOFYEAR(FROM_UNIXTIME(unix_time)) = DAYOFYEAR(DATE_SUB(NOW(), INTERVAL 1 DAY))
		  AND YEAR(FROM_UNIXTIME(unix_time)) < YEAR(NOW())
	]) or log_die("$serial: Failed to prepare statement for fallback daily usage: $DBI::errstr");
	$sth->execute() or log_die("$serial: Failed to execute statement for fallback daily usage: $DBI::errstr");

	my ($avg_daily_usage, $years_count) = $sth->fetchrow_array;
	$avg_daily_usage ||= 0;

	log_debug("$serial: Fallback: avg_daily_usage=" . sprintf("%.2f", $avg_daily_usage) .
		" from $years_count previous years");

	return undef if $avg_daily_usage <= 0;

	my $energy_last_day     = $avg_daily_usage;
	my $avg_energy_last_day = $avg_daily_usage;

	log_debug("$serial: Using fallback from samples_daily.effect, energy_last_day=" . sprintf("%.2f", $energy_last_day) .
		", avg_energy_last_day=" . sprintf("%.2f", $avg_energy_last_day));

	return { energy_last_day => $energy_last_day, avg_energy_last_day => $avg_energy_last_day };
}

1;

__END__
