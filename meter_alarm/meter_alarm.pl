#!/usr/bin/perl -w

# Anti-hysteresis:
# 1) Valve state ($closed): time-filtered using VALVE_CLOSE_DELAY to ensure the valve
#    is continuously closed before being considered valid.
#
# 2) Alarm state: cleared only after a stable normal condition for ALARM_CLEAR_DELAY
#    to prevent rapid alarm flapping due to transient conditions.

use strict;
use utf8;
use Data::Dumper;
use DBI;
use Statistics::Basic qw(:all);
use Math::Random::Secure qw(rand);
use File::Basename;
use File::Path qw(make_path);
use Redis;

use Nabovarme::Db;
use Nabovarme::Utils;

# --------------------------
# CONSTANTS
# --------------------------
# Fallback anti-hysteresis delay before clearing an active alarm (prevents flapping if DB value not set)
use constant ALARM_CLEAR_DELAY => 600;

# Fallback anti-hysteresis delay before considering valve fully closed (filters transient changes if DB value not set)
use constant VALVE_CLOSE_DELAY => 600;

# Fallback anti-hysteresis delay before treating flow as real leakage (ignores spikes if DB value not set)
use constant LEAKAGE_DELAY => 300;

# Fallback count of initial repeats without exponential backoff (used if DB value not set)
use constant INITIAL_NO_BACKOFF => 2;

use constant MAX_DATA_AGE => 86400; # seconds (e.g. 1 day)

# --------------------------------------------------
# AUTOFUSH OUTPUT ENABLED
# --------------------------------------------------
# $| = 1 forces immediate flushing of STDOUT.
$| = 1;

# Script name derived from invocation name ($0)
# Used for logging / identification purposes
my $script_name = basename($0 . ".pl");

# ==================================================
# REDIS INITIALIZATION (REAL-TIME STATE STORE)
# ==================================================
# Redis is used as a fast, ephemeral state layer for:
#   - hysteresis timers (valve/flow stability)
#   - alarm transition tracking
#   - real-time sensor cache
#
# This is NOT long-term storage — it is temporal state only.

# Redis host must be explicitly provided via environment
my $redis_host = $ENV{'REDIS_HOST'}
	or die "ERROR: REDIS_HOST environment variable not set";

# Redis port must also be explicitly provided
my $redis_port = $ENV{'REDIS_PORT'}
	or die "ERROR: REDIS_PORT environment variable not set";

# Connect to Redis server
my $redis = Redis->new(server => "$redis_host:$redis_port");

# ==================================================
# DATABASE INITIALIZATION (SYSTEM OF RECORD)
# ==================================================
# DB holds:
#   - alarm definitions
#   - meter metadata
#   - historical sensor samples
#
# Unlike Redis, DB is persistent and authoritative.
my $dbh = Nabovarme::Db->my_connect
	or log_die("Can't connect to DB: $!");

# Enable auto-reconnect to survive transient DB failures
$dbh->{'mysql_auto_reconnect'} = 1;

log_debug("Connected to DB");

# ==================================================
# SIGNAL HANDLING (GRACEFUL SHUTDOWN CONTROL)
# ==================================================
# This daemon is designed to run continuously.
# Signals allow controlled shutdown without corrupting state.

my $shutdown_requested = 0;

# --------------------------------------------------
# SIGTERM (normal service stop)
# --------------------------------------------------
# Used by systemd / orchestration systems
# → finish current loop, then exit cleanly
$SIG{TERM} = sub {
	log_debug("SIGTERM received, will shutdown after current loop...");
	$shutdown_requested = 1;
};

# --------------------------------------------------
# SIGINT (manual interruption: Ctrl+C)
# --------------------------------------------------
# Same behavior as SIGTERM for consistency
$SIG{INT} = sub {
	log_debug("SIGINT received, will shutdown after current loop...");
	$shutdown_requested = 1;
};

# --------------------------------------------------
# SIGHUP (diagnostic trigger)
# --------------------------------------------------
# Triggers a full Redis state dump for debugging:
#   - valve timers
#   - flow timers
#   - alarm transition states
$SIG{HUP} = sub {
	redis_log_snapshot();
};

# ==================================================
# RUNTIME CONFIGURATION STORE
# ==================================================
# Holds per-serial runtime overrides derived from DB + constants.
# Rebuilt each cycle in process_alarms().
my $alarm_config = {};

# ==================================================
# MAIN LOOP
# ==================================================
# This is a polling-based scheduler running forever:
#
# Cycle flow:
#   1. generate run_id (timestamp)
#   2. evaluate all alarms
#   3. optionally dump debug snapshot
#   4. sleep 60s
#
# Each loop is independent and stateless except Redis/DB.

while (1) {

	# Unique identifier for this evaluation cycle
	# Used for logging correlation across alarms
	my $run_id = time();

	log_debug("===== MAIN LOOP START run_id=$run_id =====", {
		-custom_tag => "MAIN:$run_id"
	});

	# Core system function:
	#   loads alarms → resolves state → evaluates → triggers actions
	process_alarms($run_id);

	# --------------------------------------------------
	# GRACEFUL SHUTDOWN CHECK
	# --------------------------------------------------
	# Signal handlers only set a flag.
	# Actual exit happens here between cycles.
	last if $shutdown_requested;

	# Fixed polling interval (1 minute)
	sleep 60;
}

# --------------------------
# PROCESS ALARMS
# --------------------------
# Fetches all enabled alarms and merges them with current meter metadata
sub process_alarms {
	my ($run_id) = @_;

	# --------------------------------------------------
	# LOAD ALL ACTIVE ALARMS + METER STATE (JOINED VIEW)
	# --------------------------------------------------
	# This query is the "entry point" for the entire system cycle.
	#
	# It fetches:
	#   - alarm configuration (rules, thresholds, messaging)
	#   - runtime state (last_notification, alarm_state, counters)
	#   - meter telemetry (valve state, last_updated, metadata)
	#
	# JOIN ensures each alarm evaluation has a consistent snapshot
	# of both rule + sensor state.
	my $sth = $dbh->prepare(qq[
		SELECT
			alarms.id, alarms.serial,
			alarms.condition, alarms.last_notification, alarms.alarm_state,
			alarms.repeat, alarms.alarm_count, alarms.exp_backoff_enabled,
			alarms.snooze, alarms.default_snooze,
			alarms.snooze_auth_key, alarms.sms_notification,
			alarms.down_message, alarms.up_message,
			alarms.alarm_clear_delay,
			alarms.valve_close_delay,
			alarms.initial_no_backoff,
			alarms.leakage_delay,
			meters.info, meters.valve_status, meters.valve_installed,
			meters.last_updated
		FROM alarms
		JOIN meters ON alarms.serial = meters.serial
		WHERE alarms.enabled
	]);

	$sth->execute;

	# --------------------------------------------------
	# PROCESS EACH ALARM INDEPENDENTLY
	# --------------------------------------------------
	# Each row represents a fully self-contained evaluation unit.
	while (my $alarm = $sth->fetchrow_hashref) {

		# --------------------------------------------------
		# CONFIGURATION LAYERING (DB > DEFAULT CONSTANTS)
		# --------------------------------------------------
		# Build per-serial runtime configuration.
		#
		# Priority order:
		#   1. DB override (per alarm / per meter tuning)
		#   2. System constant fallback (safe defaults)

		$alarm_config->{$alarm->{serial}} = {

			# --------------------------------------------------
			# ALARM CLEAR DELAY (hysteresis for recovery)
			# --------------------------------------------------
			alarm_clear_delay =>
				defined $alarm->{alarm_clear_delay} && $alarm->{alarm_clear_delay} ne ''
					? $alarm->{alarm_clear_delay}
					: ALARM_CLEAR_DELAY,

			# --------------------------------------------------
			# VALVE STABILITY DELAY
			# --------------------------------------------------
			# Ensures valve must remain closed continuously
			# before being treated as "closed"
			valve_close_delay =>
				defined $alarm->{valve_close_delay} && $alarm->{valve_close_delay} ne ''
					? $alarm->{valve_close_delay}
					: VALVE_CLOSE_DELAY,

			# --------------------------------------------------
			# BACKOFF CONTROL
			# --------------------------------------------------
			# Number of initial alarm repetitions before
			# exponential backoff kicks in.
			initial_no_backoff =>
				defined $alarm->{initial_no_backoff} && $alarm->{initial_no_backoff} ne ''
					? $alarm->{initial_no_backoff}
					: INITIAL_NO_BACKOFF,

			# --------------------------------------------------
			# LEAKAGE DETECTION DELAY
			# --------------------------------------------------
			# Flow must persist continuously for this duration
			# before being classified as leakage
			leakage_delay =>
				defined $alarm->{leakage_delay} && $alarm->{leakage_delay} ne ''
					? $alarm->{leakage_delay}
					: LEAKAGE_DELAY,
		};

		# --------------------------------------------------
		# CORE EVALUATION STEP
		# --------------------------------------------------
		# Each alarm is evaluated independently using:
		#   - resolved meter state
		#   - Redis hysteresis state
		#   - DB configuration rules
		#
		# This is the "decision engine" per alarm.
		evaluate_alarm($alarm, $run_id);
	}

	# Dump Redis state for debugging/timing verification
	redis_log_snapshot();
}

# --------------------------
# EVALUATE ALARM
# --------------------------
# Determines if an alarm condition is met and handles notification logic
sub evaluate_alarm {
	my ($alarm, $run_id) = @_;

	my $now = time();
	my $last_updated = $alarm->{last_updated};

	# --------------------------------------------------
	# SAFETY: IGNORE STALE DATA
	# --------------------------------------------------
	# If meter data is too old, we skip evaluation entirely.
	# This prevents:
	#   - false alarms due to disconnected devices
	#   - acting on outdated sensor values
	#
	# MAX_DATA_AGE acts as a hard cutoff (e.g. 24h)
	if (defined $last_updated && ($now - $last_updated) > MAX_DATA_AGE) {
		log_debug("Skipping alarm due to stale DB data (age=" . ($now - $last_updated) . "s)", {
			-custom_tag => "ALARM:$run_id:$alarm->{serial}"
		});
		return;
	}

	# Context
	my $serial = $alarm->{serial};
	my $cfg = $alarm_config->{$serial};

	# --------------------------------------------------
	# SNOOZE AUTH KEY MANAGEMENT
	# --------------------------------------------------
	# Each alarm notification includes a key used for snoozing.
	# Reuse existing key if present, otherwise generate a new one.
	my $snooze_auth_key = $alarm->{snooze_auth_key} || generate_snooze_key();
	my $quoted_snooze_auth_key = $dbh->quote($snooze_auth_key);

	# Raw condition string from DB (e.g. "$flow > 10 && $closed")
	my $condition = $alarm->{condition};

	# --------------------------------------------------
	# MESSAGE TEMPLATE EXPANSION
	# --------------------------------------------------
	my $down_message = fill_template($alarm->{down_message} || 'alarm', $alarm, $snooze_auth_key);
	my $up_message   = fill_template($alarm->{up_message}   || 'normal', $alarm, $snooze_auth_key);

	log_debug("raw condition: $condition", {
		-custom_tag => "ALARM:$run_id:$alarm->{serial}"
	});

	# --------------------------------------------------
	# VALVE ANTI-HYSTERESIS GATE
	# --------------------------------------------------
	# Returns:
	#   1     → valve has been stably closed for configured delay
	#   0     → valve is open or not yet confirmed stable
	#   undef → valve is transitioning (not stable yet)
	$alarm->{closed_status} = check_delayed_valve_closed($serial);

	my $uses_closed  = ($condition =~ /\$closed\b/);
	my $uses_leakage = ($condition =~ /\$leakage\b/);

	my $closed = $alarm->{closed_status};

	# --------------------------------------------------
	# ONLY SKIP IF CONDITION DEPENDS ON VALVE STATE
	# --------------------------------------------------
	if ($uses_closed || $uses_leakage) {

		# Valve still transitioning → skip evaluation
		if (!defined $closed) {
			log_debug("Skipping evaluation: valve transition still pending", {
				-custom_tag => "ALARM:$run_id:$alarm->{serial}"
			});
			
			return;
		}

		# Valve not stable closed → skip evaluation
		if ($closed == 0) {
			log_debug("Skipping evaluation: valve transition still pending", {
				-custom_tag => "ALARM:$run_id:$alarm->{serial}"
			});
			
			return;
		}
	}

	# --------------------------------------------------
	# VARIABLE INTERPOLATION
	# --------------------------------------------------
	# Replace variables in condition string:
	#   $closed → already resolved above (fast path)
	#   $flow, $temperature, etc. → resolved dynamically
	$condition = interpolate_variables($condition, $alarm);

	log_debug("parsed condition: $condition", {
		-custom_tag => "ALARM:$run_id:$alarm->{serial}"
	});

	my $eval_alarm_state;
	my $quoted_id = $dbh->quote($alarm->{id});

	# --------------------------------------------------
	# CONDITION EVALUATION (dynamic logic)
	# --------------------------------------------------
	# The condition string is evaluated as Perl code.
	# Example after interpolation:
	#   "12 > 10 && 1"
	#
	# Returns truthy/falsey → used as alarm state
	#
	# IMPORTANT:
	#   - strict/warnings disabled to allow flexible expressions
	#   - errors are caught and persisted to DB
	{
		local $@;
		no strict;
		no warnings;

		$eval_alarm_state = eval $condition;

		# --------------------------------------
		# ERROR HANDLING
		# --------------------------------------
		if ($@) {
			log_warn("Eval error: $@");

			my $err = $dbh->quote($@);

			$dbh->do(qq[
				UPDATE alarms
				SET condition_error = $err
				WHERE id = $quoted_id
			]);

			return;
		}

		log_debug("eval_result=$eval_alarm_state condition=$condition", {
			-custom_tag => "ALARM:$run_id:$alarm->{serial}"
		});

		# Clear previous error if evaluation succeeds
		$dbh->do(qq[
			UPDATE alarms
			SET condition_error = NULL
			WHERE id = $quoted_id
		]);
	}

	# --------------------------------------------------
	# STATE TRANSITION + NOTIFICATION HANDLING
	# --------------------------------------------------
	# Delegate to handle_alarm(), which manages:
	#   - alarm state transitions (0 ↔ 1)
	#   - notification sending (SMS)
	#   - repeat intervals / exponential backoff
	#   - snooze handling
	#   - anti-flapping clear delay
	handle_alarm(
		$alarm,
		$eval_alarm_state,
		$down_message,
		$up_message,
		$quoted_snooze_auth_key
	);
}

# --------------------------
# TEMPLATE
# --------------------------
# Substitutes system variables into notification text
sub fill_template {
	my ($template, $alarm, $key) = @_;

	$template =~ s/\$snooze_auth_key/$key/g;
	$template =~ s/\$default_snooze/$alarm->{default_snooze}/g;
	$template =~ s/\$serial/$alarm->{serial}/g;
	$template =~ s/\$id/$alarm->{id}/g;

	return interpolate_variables($template, $alarm);
}

# --------------------------
# VALVE LOGIC (REDIS)
# --------------------------
# Ensures the valve has been closed continuously for VALVE_CLOSE_DELAY seconds
sub check_delayed_valve_closed {
	my ($serial) = @_;

	# Per-serial configuration
	my $cfg = $alarm_config->{$serial};

	# --------------------------------------------------
	# FETCH CURRENT VALVE STATE FROM DB
	# --------------------------------------------------
	# We rely on DB as the source of truth for:
	#   - valve_status (e.g. "closed", "open")
	#   - valve_installed (boolean flag)
	#
	# NOTE: This is intentionally not cached in Redis,
	# since correctness is more important than speed here.
	my $sth = $dbh->prepare("SELECT valve_status, valve_installed FROM meters WHERE serial = ?");
	$sth->execute($serial);
	my ($status, $installed) = $sth->fetchrow_array;

	# Redis key used to track *when* the valve was first observed closed
	my $key = "valve:$serial:closed_since";

	my $now = time();

	# --------------------------------------------------
	# CASE 1: VALVE NOT CLOSED (or not installed)
	# --------------------------------------------------
	# If:
	#   - valve is open
	#   - valve is missing
	#   - status does not match "close"
	#
	# Then:
	#   - Reset any existing timer (important!)
	#   - Immediately return 0 (definitively NOT closed)
	#
	# This ensures that "closed" must be continuous
	# — any interruption resets the hysteresis window.
	unless ($installed && $status =~ /close/i) {
		$redis->del($key);
		return 0;
	}

	# --------------------------------------------------
	# CASE 2: VALVE JUST BECAME CLOSED (start timing)
	# --------------------------------------------------
	# Check when we first observed "closed"
	my $closed_since = $redis->get($key);

	# If no valid timestamp exists:
	#   - This is the FIRST detection of closed state
	#   - Start a timer in Redis
	#   - Return undef (not stable yet)
	if (!$closed_since || $closed_since !~ /^\d+$/) {
		$redis->set($key, $now, 'EX', 3600);

		# undef signals:
		#   "we are in transition, do not evaluate alarm yet"
		return undef;
	}

	# --------------------------------------------------
	# CASE 3: VALVE CLOSED LONG ENOUGH (stable state)
	# --------------------------------------------------
	# Only consider valve truly closed if it has remained
	# closed continuously for valve_close_delay seconds.
	#
	# This prevents:
	#   - rapid open/close jitter
	#   - transient reporting glitches
	#
	# Return values:
	#   1     → closed (stable)
	#   undef → still waiting for stability
	return ($now - $closed_since >= $cfg->{valve_close_delay}) ? 1 : undef;
}

# --------------------------
# VARIABLE RESOLVER
# --------------------------
# Iterates through text to find and replace $variable tokens
sub interpolate_variables {
	my ($text, $alarm) = @_;

	# Extract all $variable tokens from the expression
	my @vars = ($text =~ /\$(\w+)/g);

	foreach my $var (@vars) {

		# Resolve each variable against alarm/meter state
		my $value = resolve_var($var, $alarm);

		# Normalize missing/undefined values to 0 for safe evaluation
		$value = 0 if !defined $value || $value eq '';

		# Replace all occurrences of $var with its resolved value
		$text =~ s/\$$var\b/$value/g;
	}

	return $text;
}

# Core logic for fetching sensor data from Redis or DB
# --------------------------------------------------
# Handles arbitrary sensor variables like:
#   $temperature, $pressure, etc.
#
# Resolution strategy:
#   1. Query DB for recent samples
#   2. Compute a stable value (median of last samples)
# --------------------------------------------------
sub resolve_var {
	my ($var, $alarm) = @_;

	# Context
	my $serial = $alarm->{serial};
	my $cfg = $alarm_config->{$serial};

	# --------------------------------------------------
	# DIRECT FIELD MAPPINGS (no computation)
	# --------------------------------------------------
	# These variables come directly from the already-fetched
	# alarm + meter JOIN query → no need for Redis/DB lookup.
	if ($var eq 'info' || $var eq 'valve_status' || $var eq 'valve_installed' || $var eq 'last_updated') {
		return $alarm->{$var};
	}

	# Return device serial
	if ($var eq 'serial') {
		return $serial;
	}

	# --------------------------------------------------
	# OFFLINE DETECTION
	# --------------------------------------------------
	# Returns "seconds since last update"
	# → allows conditions like: $offline > 600
	# Note: this does a DB lookup each time (potential hotspot)
	if ($var eq 'offline') {
		my $sth = $dbh->prepare("SELECT last_updated FROM meters WHERE serial = ?");
		$sth->execute($serial);
		my ($lu) = $sth->fetchrow_array;

		# If no timestamp exists, treat as "just updated"
		# (prevents false massive offline values)
		return time() - ($lu || time());
	}

	# --------------------------------------------------
	# VALVE STATE (already anti-hysteresis filtered upstream)
	# --------------------------------------------------
	# This value is precomputed by check_delayed_valve_closed()
	# and represents a *stable* interpretation:
	#   1 = closed (stable)
	#   0 = open
	#   undef = still transitioning (handled earlier)
	if ($var eq 'closed') {
		return $alarm->{closed_status};
	}

	# --------------------------------------------------
	# LEAKAGE DETECTION (time-filtered flow)
	# --------------------------------------------------
	# This implements temporal hysteresis:
	#   flow must be > 0 continuously for leakage_delay seconds
	#
	# Returns:
	#   0     → no leakage (or not stable yet)
	#   >0    → leakage (actual flow value)
	#
	# NOTE: returns FLOW VALUE, not boolean
	if ($var eq 'leakage') {

		# Only allow leakage evaluation if valve state is confirmed as
		# stably CLOSED (i.e. passed hysteresis check via check_delayed_valve_closed()).
		# Reject:
		#   - undef → valve still transitioning (not stable yet)
		#   - 0     → valve is open or invalid state
		# Accept only:
		#   - 1     → stable closed state

		unless (defined $alarm->{closed_status} && $alarm->{closed_status} == 1) {
			return 0;
		}
		

		my $key = "flow:$serial:leak_since";
		my $now = time();

		my $sth = $dbh->prepare(qq[
			SELECT flow
			FROM samples_cache
			WHERE serial = ?
			ORDER BY unix_time DESC
			LIMIT 1
		]);

		$sth->execute($serial);
		my ($flow) = $sth->fetchrow_array;

		$flow ||= 0;

		if ($flow <= 0) {
			$redis->del($key);
			return 0;
		}

		my $since = $redis->get($key);

		if (!$since || $since !~ /^\d+$/) {
			$redis->set($key, $now, 'EX', 3600);
			return 0;
		}

		return ($now - $since >= $cfg->{leakage_delay}) ? $flow : 0;
	}

	# --------------------------------------------------
	# DAILY DELTA CALCULATIONS (volume / energy)
	# --------------------------------------------------
	# Computes usage over last 24h (minus delay window)
	#
	# Why subtract delay?
	# → Aligns with valve hysteresis so we don't include
	#   unstable transition periods in calculations.
	#
	# Uses "first value" and "last value" approach:
	#   delta = last - first
	if ($var eq 'volume_day' or $var eq 'energy_day') {

		my $column = $var eq 'volume_day' ? 'volume' : 'energy';

		# Extend window backwards by valve delay to avoid edge effects
		my $delay = $alarm_config->{$serial}->{valve_close_delay} // VALVE_CLOSE_DELAY;
		my $since = time() - 86400 - $delay;

		# --------------------------------------
		# STEP 1: Get earliest value in window
		# --------------------------------------
		my $sth = $dbh->prepare(qq[
			SELECT $column
			FROM samples_cache
			WHERE serial = ?
			AND unix_time > ?
			ORDER BY unix_time ASC
			LIMIT 1
		]);

		$sth->execute($serial, $since);
		my ($first_val) = $sth->fetchrow_array;
		$first_val = 0 unless defined $first_val;

		# --------------------------------------
		# STEP 2: Get latest value in window
		# --------------------------------------
		$sth = $dbh->prepare(qq[
			SELECT $column
			FROM samples_cache
			WHERE serial = ?
			AND unix_time > ?
			ORDER BY unix_time DESC
			LIMIT 1
		]);

		$sth->execute($serial, $since);
		my ($last_val) = $sth->fetchrow_array;
		$last_val = 0 unless defined $last_val;

		# --------------------------------------
		# STEP 3: Compute delta
		# --------------------------------------
		my $delta = $last_val - $first_val;

		# Protect against counter reset / rollover
		# (e.g. meter restart or overflow)
		$delta = 0 if $delta < 0;

		return $delta + 0; # force numeric
	}
	
	# --------------------------------------------------
	# GENERIC SENSOR FALLBACK
	# --------------------------------------------------
	# Handles arbitrary variables like:
	#   $temperature, $pressure, etc.
	my $sth = $dbh->prepare(qq[
		SELECT `$var`
		FROM samples_cache
		WHERE serial = ?
		ORDER BY unix_time DESC
		LIMIT 5
	]);

	$sth->execute($serial);
	my $rows = $sth->fetchall_arrayref;

	return undef unless @$rows;

	# Extract numeric values, ignore NULLs
	my @values = map {
		defined $_->[0] ? $_->[0] + 0.0 : ()
	} @$rows;

	return undef unless @values;

	# Use median: robust against spikes / outliers
	my $median_val = median(@values);

	return $median_val + 0.0;
}

# --------------------------
# ALARM HANDLER
# --------------------------
# Manages state changes, snooze, and exponential backoff for notifications
# --------------------------
# ALARM HANDLER
# --------------------------
# Manages state changes, snooze, and exponential backoff for notifications
sub handle_alarm {
	my ($alarm, $state, $down, $up, $key) = @_;

	# Basic context
	my $serial = $alarm->{serial};
	my $cfg = $alarm_config->{$serial};

	# Quote ID for safe SQL usage
	my $id   = $dbh->quote($alarm->{id});
	my $now  = time();

	# Redis key used to track when a "normal" (non-alarm) condition started.
	# This enables delayed clearing (anti-flapping).
	my $redis_clear_key = "alarm:$alarm->{id}:clear_pending_since";

	# Redis key used to persist serial ↔ alarm mapping
	my $redis_serial_key = "alarm:$alarm->{id}:serial";

	# Number of times this alarm has been triggered (used for backoff logic)
	my $count = $alarm->{alarm_count} || 0;

	# Ensure serial is always available in Redis for observability/debugging
	if (defined $serial && $serial ne '') {
		$redis->set($redis_serial_key, $serial);
	} else {
		# Fallback: recover serial from Redis if DB value is missing
		$serial = $redis->get($redis_serial_key) // 'UNKNOWN';
	}

	# ==================================================
	# ALARM ACTIVE STATE (condition is TRUE)
	# ==================================================
	if ($state) {

		# If alarm is active again, cancel any pending "clear" timer.
		# This prevents clearing if condition briefly returned to normal.
		$redis->del($redis_clear_key);

		# Determine whether exponential backoff should be used
		# Disabled if repeat interval is very large (>= 1 day)
		my $use_backoff = ($alarm->{exp_backoff_enabled} && $alarm->{repeat} < 86400) ? 1 : 0;

		# --------------------------------------------------
		# FIRST ACTIVATION (alarm transitions from 0 → 1)
		# --------------------------------------------------
		if ($alarm->{alarm_state} == 0) {

			# Send initial alarm notification immediately
			sms_send($alarm->{sms_notification}, $down);

			# Reset counter to 1 (first occurrence)
			$count = 1;

			# Persist new alarm state in DB
			$dbh->do(qq[
				UPDATE alarms
				SET alarm_state=1,
					last_notification=$now,
					alarm_count=$count,
					snooze_auth_key=$key
				WHERE id=$id
			]);

		# --------------------------------------------------
		# REPEATED NOTIFICATIONS (alarm already active)
		# --------------------------------------------------
		} elsif ($alarm->{repeat}) {

			my $interval;

			# Apply exponential backoff after N initial notifications
			# Example:
			#   repeat = 60s, initial_no_backoff = 2
			#   → 60s, 60s, 120s, 240s, 480s, ...
			if ($use_backoff && $count >= $cfg->{initial_no_backoff}) {
				$interval = $alarm->{repeat} * (2 ** ($count - $cfg->{initial_no_backoff}));

				# Cap interval to 24 hours to avoid excessive silence
				$interval = 86400 if $interval > 86400;
			} else {
				# Fixed repeat interval (no backoff yet)
				$interval = $alarm->{repeat};
			}

			# Only proceed with notification logic if we are outside the snooze window
			# This keeps the DB "frozen" (no count increase, no timestamp update) while snoozed
			if (($alarm->{last_notification} + $interval + $alarm->{snooze}) < $now) {

				# Send repeated alarm notification
				sms_send($alarm->{sms_notification}, $down);

				# Increment occurrence count (affects future backoff)
				$count++;

				# Persist updated state
				$dbh->do(qq[
					UPDATE alarms
					SET last_notification=$now,
						alarm_state=1,
						alarm_count=$count,
						snooze=0,
						snooze_auth_key=$key
					WHERE id=$id
				]);
			}
		}

	# ==================================================
	# ALARM CLEARING STATE (condition is FALSE)
	# ==================================================
	} else {

		# Check when the system first observed a "normal" condition
		my $since = $redis->get($redis_clear_key);

		# --------------------------------------------------
		# STEP 1: Start clear timer
		# --------------------------------------------------
		# If this is the first time we see a normal state,
		# start a timer instead of clearing immediately.
		# Only begin clear hysteresis if alarm is currently active
		if ($alarm->{alarm_state} == 1 && !$since) {

			$redis->set($redis_clear_key, $now, 'EX', 3600);

			# reset snooze immediately on recovery start
			$dbh->do(qq[
			UPDATE alarms
			SET snooze = 0
			WHERE id = $id
			]);

			return;
		}

		# --------------------------------------------------
		# STEP 2: Enforce stability window
		# --------------------------------------------------
		# Only clear alarm if condition has remained normal
		# continuously for alarm_clear_delay seconds
		if (($now - $since) < $cfg->{alarm_clear_delay}) {
			return; # still within hysteresis window → do nothing
		}

		# --------------------------------------------------
		# STEP 3: Clear alarm if it was previously active
		# --------------------------------------------------
		if ($alarm->{alarm_state} == 1) {

			# Send "recovery" / "back to normal" notification
			sms_send($alarm->{sms_notification}, $up);

			# Reset alarm state in DB
			$dbh->do(qq[
				UPDATE alarms
				SET alarm_state=0,
					alarm_count=0,
					snooze=0,
					snooze_auth_key=NULL
				WHERE id=$id
			]);
		}

		# Cleanup: remove clear timer after successful resolution
		$redis->del($redis_clear_key);
	}
}

# --------------------------
# SMS
# --------------------------
sub sms_send {
	my ($to, $msg) = @_;
	return unless $to;

	for my $r ($to =~ /\d+/g) {
		log_debug("SMS -> 45$r: $msg");
		send_notification($r, $msg);
	}
}

sub generate_snooze_key {
	return join('', map { sprintf("%02x", int rand(256)) } 1..8);
}

# --------------------------
# REDIS STARTUP
# --------------------------
# Iterates through Redis to log current state of all meters and pending alarms
sub redis_log_snapshot {
	log_debug("===== REDIS LOG SNAPSHOT BEGIN =====");

	my $cursor = 0;
	my $now = time();

	my %meters;
	my %alarms;

	# --------------------------
	# SCAN REDIS
	# --------------------------
	do {
		my ($new_cursor, $keys) = $redis->scan($cursor, 'COUNT', 500);
		$cursor = $new_cursor;

		foreach my $key (@$keys) {

			if ($key =~ /^(sensor|valve|flow):(\d+):/) {

				my $serial = $2;
				my $val = $redis->get($key);

				$meters{$serial}{$key} = $val;
			}

			elsif ($key =~ /^alarm:(\d+):(.*)$/) {

				my $alarm_id = $1;
				my $field    = $2;
				my $val      = $redis->get($key);

				$alarms{$alarm_id}{$field} = $val;
			}
		}

	} while ($cursor != 0);

	# ==================================================
	# METERS
	# ==================================================
	log_debug("---- METER STATE BY SERIAL ----");

	foreach my $serial (sort { $a <=> $b } keys %meters) {

		log_debug("== SERIAL $serial ==");

		foreach my $key (sort keys %{ $meters{$serial} }) {

			my $val = $meters{$serial}{$key};

			if (!defined $val || $val eq '') {
				log_debug("  $key => <empty>");
				next;
			}

			my ($age, $delay, $state);

			$state = "STATIC";

			if ($key =~ /_since$/) {
				$age = $now - $val;

				if ($key =~ /valve/) {
					$delay = VALVE_CLOSE_DELAY;
					$state = ($age >= $delay) ? "STABLE" : "TRANSITION";
				}
				elsif ($key =~ /flow/) {
					$delay = LEAKAGE_DELAY;
					$state = ($age >= $delay) ? "STABLE" : "TRANSITION";
				}
				else {
					$state = "TIMED_EVENT";
				}
			}

			if (defined $age) {
				log_debug(sprintf(
					"  %s => %s (state=%s, age=%ds, delay=%ds, remaining=%ds)",
					$key, $val, $state, $age, ($delay // 0), (($delay // 0) - $age)
				));
			} else {
				log_debug("  $key => $val (state=$state)");
			}
		}
	}

	# ==================================================
	# ALARMS
	# ==================================================
	log_debug("---- ALARM STATE ----");

	foreach my $alarm_id (sort { $a <=> $b } keys %alarms) {

		my $serial = $alarms{$alarm_id}{serial};

		if (!defined $serial || $serial eq '') {
			log_warn("Alarm $alarm_id missing serial in Redis snapshot, skipping");
			next;
		}

		my $alarm_state = $alarms{$alarm_id}{alarm_state} // 0;

		log_debug("== ALARM $alarm_id (SERIAL $serial) ==");

		my $cfg = $alarm_config->{$serial} // {};

		log_debug(sprintf(
			"  CONFIG: alarm_clear_delay=%ds, valve_close_delay=%ds, leakage_delay=%ds, initial_no_backoff=%s",
			($cfg->{alarm_clear_delay} // ALARM_CLEAR_DELAY),
			($cfg->{valve_close_delay} // VALVE_CLOSE_DELAY),
			($cfg->{leakage_delay} // LEAKAGE_DELAY),
			($cfg->{initial_no_backoff} // INITIAL_NO_BACKOFF),
		));

		my $base_delay = $cfg->{alarm_clear_delay} // ALARM_CLEAR_DELAY;

		my $clear_since = $alarms{$alarm_id}{clear_pending_since};
		my $clear_age;

		if (defined $clear_since && $clear_since =~ /^\d+$/) {
			$clear_age = $now - $clear_since;
		}

		my $state = "IDLE";

		if ($alarm_state) {
			$state = "ACTIVE";
		}

		if ($alarm_state && defined $clear_since) {
			$state = "CLEARING";
		}
		elsif (!$alarm_state && defined $clear_since && defined $clear_age && $clear_age < $base_delay) {
			$state = "WAITING";
		}

		foreach my $key (sort keys %{ $alarms{$alarm_id} }) {

			my $val = $alarms{$alarm_id}{$key};
			next unless defined $val && $val ne '';

			my ($age, $effective_delay);

			$effective_delay = $base_delay;

			if ($key =~ /_since$/) {
				$age = $now - $val;
			}

			if ($key =~ /valve/) {
				$effective_delay = $cfg->{valve_close_delay} // VALVE_CLOSE_DELAY;
			}
			elsif ($key =~ /flow/) {
				$effective_delay = $cfg->{leakage_delay} // LEAKAGE_DELAY;
			}

			if (defined $age) {
				log_debug(sprintf(
					"  %s => %s (state=%s, age=%ds, delay=%ds, remaining=%ds)",
					$key, $val, $state, $age, $effective_delay, ($effective_delay - $age)
				));
			}
			else {
				log_debug(sprintf(
					"  %s => %s (state=%s)",
					$key, $val, $state
				));
			}
		}
	}
}
