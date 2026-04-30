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

$| = 1;

my $script_name = basename($0 . ".pl");

# --------------------------
# REDIS
# --------------------------
# Redis stores real-time timestamps to track how long a condition has been true (anti-hysteresis)
my $redis_host = $ENV{'REDIS_HOST'}
	or die "ERROR: REDIS_HOST environment variable not set";

my $redis_port = $ENV{'REDIS_PORT'}
	or die "ERROR: REDIS_PORT environment variable not set";

my $redis = Redis->new(server => "$redis_host:$redis_port");

# --------------------------
# DB
# --------------------------
my $dbh = Nabovarme::Db->my_connect or log_die("Can't connect to DB: $!");
$dbh->{'mysql_auto_reconnect'} = 1;

log_debug("Connected to DB");

# --------------------------
# SIGNALS
# --------------------------
my $shutdown_requested = 0;

$SIG{TERM} = sub {
	log_debug("SIGTERM received, will shutdown after current loop...");
	$shutdown_requested = 1;
};

$SIG{INT} = sub {
	log_debug("SIGINT received, will shutdown after current loop...");
	$shutdown_requested = 1;
};

# SIGHUP can be used to trigger a status dump of all internal Redis timers to logs
$SIG{HUP} = sub {
	redis_log_snapshot();
};

# --------------------------
# CONFIG
# --------------------------
my $alarm_config = {};

# --------------------------
# MAIN LOOP
# --------------------------
while (1) {
	my $run_id = time();

	log_debug("===== MAIN LOOP START run_id=$run_id =====", {
		-custom_tag => "MAIN:$run_id"
	});

	process_alarms($run_id);

	last if $shutdown_requested;
	sleep 60;
}

# --------------------------
# PROCESS ALARMS
# --------------------------
# Fetches all enabled alarms and merges them with current meter metadata
sub process_alarms {
	my ($run_id) = @_;

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

	while (my $alarm = $sth->fetchrow_hashref) {
		# Configuration hierarchy: DB setting > Constant fallback
		$alarm_config->{$alarm->{serial}} = {
			alarm_clear_delay =>
				defined $alarm->{alarm_clear_delay} && $alarm->{alarm_clear_delay} ne ''
					? $alarm->{alarm_clear_delay}
					: ALARM_CLEAR_DELAY,

			valve_close_delay =>
				defined $alarm->{valve_close_delay} && $alarm->{valve_close_delay} ne ''
					? $alarm->{valve_close_delay}
					: VALVE_CLOSE_DELAY,

			initial_no_backoff =>
				defined $alarm->{initial_no_backoff} && $alarm->{initial_no_backoff} ne ''
					? $alarm->{initial_no_backoff}
					: INITIAL_NO_BACKOFF,

			leakage_delay =>
				defined $alarm->{leakage_delay} && $alarm->{leakage_delay} ne ''
					? $alarm->{leakage_delay}
					: LEAKAGE_DELAY,
		};
		evaluate_alarm($alarm, $run_id);
	}
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

	# Safety: ignore data older than 24 hours
	if (defined $last_updated && ($now - $last_updated) > MAX_DATA_AGE) {
		log_debug("Skipping alarm due to stale DB data (age=" . ($now - $last_updated) . "s)", {
			-custom_tag => "ALARM:$run_id:$alarm->{serial}"
		});
		return;
	}

	my $serial = $alarm->{serial};
	my $cfg = $alarm_config->{$serial};

	my $snooze_auth_key = $alarm->{snooze_auth_key} || generate_snooze_key();
	my $quoted_snooze_auth_key = $dbh->quote($snooze_auth_key);

	my $condition = $alarm->{condition};

	# Prepare messages with substituted values
	my $down_message = fill_template($alarm->{down_message} || 'alarm', $alarm, $snooze_auth_key);
	my $up_message   = fill_template($alarm->{up_message}   || 'normal', $alarm, $snooze_auth_key);

	log_debug("raw condition: $condition", {
		-custom_tag => "ALARM:$run_id:$alarm->{serial}"
	});

	# Anti-hysteresis check for valve closure
	my $closed_status = check_delayed_valve_closed($serial);
	return if not defined $closed_status;

	$alarm->{closed_status} = $closed_status;

	# Variable interpolation: replacing tokens like $flow or $closed with real data
	$condition =~ s/\$closed/$closed_status/g;
	$condition = interpolate_variables($condition, $alarm);

	log_debug("parsed condition: $condition", {
		-custom_tag => "ALARM:$run_id:$alarm->{serial}"
	});

	my $eval_alarm_state;
	my $quoted_id = $dbh->quote($alarm->{id});

	# Safe evaluation of the condition string as Perl logic
	{
		local $@;
		no strict;
		no warnings;

		$eval_alarm_state = eval $condition;

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

		$dbh->do(qq[
			UPDATE alarms
			SET condition_error = NULL
			WHERE id = $quoted_id
		]);
	}

	# Delegate to handle_alarm for state transitions and SMS sending
	handle_alarm($alarm, $eval_alarm_state, $down_message, $up_message, $quoted_snooze_auth_key);
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

	my $cfg = $alarm_config->{$serial};

	my $sth = $dbh->prepare("SELECT valve_status, valve_installed FROM meters WHERE serial = ?");
	$sth->execute($serial);
	my ($status, $installed) = $sth->fetchrow_array;

	my $key = "valve:$serial:closed_since";
	my $now = time();

	# If valve is open or missing, clear timer and return 0 (open)
	unless ($installed && $status =~ /close/i) {
		$redis->del($key);
		return 0;
	}

	my $closed_since = $redis->get($key);

	# If first detection, set start time in Redis
	if (!$closed_since || $closed_since !~ /^\d+$/) {
		$redis->set($key, $now, 'EX', 3600);
		return undef;
	}

	# Only return 1 (closed) if enough time has passed
	return ($now - $closed_since >= $cfg->{valve_close_delay}) ? 1 : undef;
}

# --------------------------
# VARIABLE RESOLVER
# --------------------------
# Iterates through text to find and replace $variable tokens
sub interpolate_variables {
	my ($text, $alarm) = @_;

	my @vars = ($text =~ /\$(\w+)/g);

	foreach my $var (@vars) {

		my $value = resolve_var($var, $alarm);

		$value = 0 if !defined $value || $value eq '';

		$text =~ s/\$$var\b/$value/g;
	}

	return $text;
}

# Core logic for fetching sensor data from Redis or DB
sub resolve_var {
	my ($var, $alarm) = @_;

	my $serial = $alarm->{serial};
	my $cfg = $alarm_config->{$serial};

	if ($var eq 'info' || $var eq 'valve_status' || $var eq 'valve_installed' || $var eq 'last_updated') {
		return $alarm->{$var};
	}

	if ($var eq 'serial') {
		return $serial;
	}

	if ($var eq 'offline') {
		my $sth = $dbh->prepare("SELECT last_updated FROM meters WHERE serial = ?");
		$sth->execute($serial);
		my ($lu) = $sth->fetchrow_array;
		return time() - ($lu || time());
	}

	if ($var eq 'closed') {
		return $alarm->{closed_status};
	}

	# Leakage logic: requires flow to be > 0 for LEAKAGE_DELAY seconds
	if ($var eq 'leakage') {

		my $key = "flow:$serial:leak_since";
		my $now = time();

		# direct flow lookup (no recursion)
		my $flow;

		my $redis_key = "sensor:$serial:flow:last_value";
		$flow = $redis->get($redis_key);

		if (!defined $flow || $flow eq '') {

			my $sth = $dbh->prepare(qq[
				SELECT flow
				FROM samples_cache
				WHERE serial = ?
				ORDER BY unix_time DESC
				LIMIT 1
			]);

			$sth->execute($serial);
			($flow) = $sth->fetchrow_array;
		}

		$flow ||= 0;

		# no flow → reset timer
		if ($flow <= 0) {
			$redis->del($key);
			return 0;
		}

		my $since = $redis->get($key);

		# first detection → start timer
		if (!$since || $since !~ /^\d+$/) {
			$redis->set($key, $now, 'EX', 3600);
			return 0;
		}

		# only count as leakage after delay
		return ($now - $since >= $cfg->{leakage_delay}) ? $flow : 0;
	}

	# volume_day / energy_day calculated over last 24h - delay window
	if ($var eq 'volume_day' or $var eq 'energy_day') {

		my $column = $var eq 'volume_day' ? 'volume' : 'energy';

		my $delay = $alarm_config->{$serial}->{valve_close_delay} // VALVE_CLOSE_DELAY;
		my $since = time() - 86400 - $delay;

		# Get earliest sample after time window
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

		# Get latest sample in same window
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

		my $delta = $last_val - $first_val;

		# Protect against counter resets / rollover
		$delta = 0 if $delta < 0;

		return $delta + 0;
	}
	
	# ---- generic sensor fallback ----
	my $redis_key = "sensor:$serial:$var:last_value";
	my $val = $redis->get($redis_key);

	if (!defined $val || $val eq '') {

		my $quoted_var = '`' . $var . '`';

		my $sth = $dbh->prepare(qq[
			SELECT $quoted_var
			FROM samples_cache
			WHERE serial = ?
			ORDER BY unix_time DESC
			LIMIT 5
		]);

		$sth->execute($serial);
		my $rows = $sth->fetchall_arrayref;

		return undef unless @$rows;

		my @values = map {
			defined $_->[0] ? $_->[0] + 0.0 : ()
		} @$rows;

		return undef unless @values;

		my $median_val = median(@values);

		return $median_val + 0.0;
	}

	return $val + 0;
}

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
	# (useful for debugging / snapshot logging even if DB data is incomplete)
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

			# Check if enough time has passed since last notification
			# Includes snooze delay (user-suppressed notifications)
			if (($alarm->{last_notification} + $interval + $alarm->{snooze}) < $now) {

				# Send repeated alarm notification
				sms_send($alarm->{sms_notification}, $down);

				# Increment occurrence count (affects future backoff)
				$count++;

				# Update in-memory timestamp (used for next iteration)
				$alarm->{last_notification} = $now;

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
		if (!$since) {
			$redis->set($redis_clear_key, $now, 'EX', 3600);
			return; # wait for stability before clearing
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
					snooze_auth_key=''
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
