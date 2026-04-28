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

$| = 1;

my $script_name = basename($0 . ".pl");

# --------------------------
# REDIS
# --------------------------
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

log_info("Connected to DB");

# --------------------------
# SIGNALS
# --------------------------
my $shutdown_requested = 0;

$SIG{TERM} = sub {
	log_info("SIGTERM received, will shutdown after current loop...");
	$shutdown_requested = 1;
};

$SIG{INT} = sub {
	log_info("SIGINT received, will shutdown after current loop...");
	$shutdown_requested = 1;
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
}

# --------------------------
# EVALUATE ALARM
# --------------------------
sub evaluate_alarm {
	my ($alarm, $run_id) = @_;

	my $serial = $alarm->{serial};
	my $cfg = $alarm_config->{$serial};

	my $snooze_auth_key = $alarm->{snooze_auth_key} || generate_snooze_key();
	my $quoted_snooze_auth_key = $dbh->quote($snooze_auth_key);

	my $condition = $alarm->{condition};

	my $down_message = fill_template($alarm->{down_message} || 'alarm', $alarm, $snooze_auth_key);
	my $up_message   = fill_template($alarm->{up_message}   || 'normal', $alarm, $snooze_auth_key);

	log_debug("raw condition: $condition", {
		-custom_tag => "ALARM:$run_id:$alarm->{serial}"
	});

	my $closed_status = check_delayed_valve_closed($serial);
	return if not defined $closed_status;

	$alarm->{closed_status} = $closed_status;

	$condition =~ s/\$closed/$closed_status/g;
	$condition = interpolate_variables($condition, $alarm);

	log_debug("parsed condition: $condition", {
		-custom_tag => "ALARM:$run_id:$alarm->{serial}"
	});

	my $eval_alarm_state;
	my $quoted_id = $dbh->quote($alarm->{id});

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

	handle_alarm($alarm, $eval_alarm_state, $down_message, $up_message, $quoted_snooze_auth_key);
}

# --------------------------
# TEMPLATE
# --------------------------
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
sub check_delayed_valve_closed {
	my ($serial) = @_;

	my $cfg = $alarm_config->{$serial};

	my $sth = $dbh->prepare("SELECT valve_status, valve_installed FROM meters WHERE serial = ?");
	$sth->execute($serial);
	my ($status, $installed) = $sth->fetchrow_array;

	my $key = "valve:$serial:closed_since";
	my $now = time();

	# Not closed → reset
	unless ($installed && $status =~ /close/i) {
		$redis->del($key);
		return 0;
	}

	my $closed_since = $redis->get($key);

	# First detection (start timer)
	if (!$closed_since || $closed_since !~ /^\d+$/) {
		$redis->set($key, $now, 'EX', 3600);
		return undef;
	}

	# Still within delay window
	return ($now - $closed_since >= $cfg->{valve_close_delay}) ? 1 : undef;
}

# --------------------------
# VARIABLE RESOLVER
# --------------------------
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

	# ---- generic sensor fallback ----
	my $redis_key = "sensor:$serial:$var:last_value";
	my $val = $redis->get($redis_key);

	if (!defined $val || $val eq '') {

		my $sth = $dbh->prepare(qq[
			SELECT `$var`
			FROM samples_cache
			WHERE serial = ?
			ORDER BY unix_time DESC
			LIMIT 1
		]);

		$sth->execute($serial);
		($val) = $sth->fetchrow_array;

		return undef unless defined $val;
	}

	return $val + 0;
}

# --------------------------
# ALARM HANDLER
# --------------------------
sub handle_alarm {
	my ($alarm, $state, $down, $up, $key) = @_;

	my $serial = $alarm->{serial};
	my $cfg = $alarm_config->{$serial};

	my $id   = $dbh->quote($alarm->{id});
	my $now  = time();

	my $redis_clear_key = "alarm:$alarm->{id}:clear_pending_since";
	my $clear_delay = $cfg->{alarm_clear_delay};

	my $count = $alarm->{alarm_count} || 0;

	if ($state) {

		$redis->del($redis_clear_key);

		my $use_backoff = ($alarm->{exp_backoff_enabled} && $alarm->{repeat} < 86400) ? 1 : 0;

		if ($alarm->{alarm_state} == 0) {

			sms_send($alarm->{sms_notification}, $down);
			$count = 1;

			$dbh->do(qq[
				UPDATE alarms
				SET alarm_state=1,
					last_notification=$now,
					alarm_count=$count,
					snooze_auth_key=$key
				WHERE id=$id
			]);

		} elsif ($alarm->{repeat}) {

			my $interval;

			if ($use_backoff && $count >= $cfg->{initial_no_backoff}) {
				$interval = $alarm->{repeat} * (2 ** ($count - $cfg->{initial_no_backoff}));
				$interval = 86400 if $interval > 86400;
			} else {
				$interval = $alarm->{repeat};
			}

			if (($alarm->{last_notification} + $interval + $alarm->{snooze}) < $now) {

				sms_send($alarm->{sms_notification}, $down);
				$count++;

				$alarm->{last_notification} = $now;

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

	} else {

		my $since = $redis->get($redis_clear_key);

		if (!$since) {
			$redis->set($redis_clear_key, $now, 'EX', 3600);
			return;
		}

		if (($now - $since) < $clear_delay) {
			return;
		}

		if ($alarm->{alarm_state} == 1) {

			sms_send($alarm->{sms_notification}, $up);

			$dbh->do(qq[
				UPDATE alarms
				SET alarm_state=0,
					alarm_count=0,
					snooze=0,
					snooze_auth_key=''
				WHERE id=$id
			]);
		}

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
		log_info("SMS -> 45$r: $msg");
		send_notification($r, $msg);
	}
}

sub generate_snooze_key {
	return join('', map { sprintf("%02x", int rand(256)) } 1..8);
}