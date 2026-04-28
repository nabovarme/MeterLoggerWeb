#!/usr/bin/perl -w

# Perl script to monitor alarms from IoT meters and send SMS notifications
# when certain conditions (like valve closure or abnormal energy usage) are met.

use strict;
use utf8;
use Data::Dumper;
use DBI;
use Statistics::Basic qw(:all);	 # for computing medians
use Math::Random::Secure qw(rand);
use File::Basename;
use Storable qw(store retrieve);
use File::Path qw(make_path);
use Redis;

use Nabovarme::Db;
use Nabovarme::Utils;

# Constants
use constant VALVE_CLOSE_DELAY => 600;  # 10 minutes delay used in metrics
use constant INITIAL_NO_BACKOFF => 2;   # first N notifications sent without exponential backoff
use constant EMA_ALPHA => 0.2;
use constant THRESHOLD_PERCENT => 2;

$| = 1;  # Autoflush STDOUT to ensure logs appear immediately

my $script_name = basename($0 . ".pl");

# Redis connection
my $redis_host = $ENV{'REDIS_HOST'}
	or die "ERROR: REDIS_HOST environment variable not set";

my $redis_port = $ENV{'REDIS_PORT'}
	or die "ERROR: REDIS_PORT environment variable not set";

my $redis = Redis->new(
	server => "$redis_host:$redis_port",
);

my $shutdown_requested = 0;

# DB
my $dbh = Nabovarme::Db->my_connect or log_die("Can't connect to DB: $!");
$dbh->{'mysql_auto_reconnect'} = 1;

log_info("Connected to DB");

# Signals
$SIG{TERM} = sub {
	log_info("SIGTERM received, will shutdown after current loop...");
	$shutdown_requested = 1;
};

$SIG{INT} = sub {
	log_info("SIGINT received, will shutdown after current loop...");
	$shutdown_requested = 1;
};

# MAIN LOOP
my $run_id;
while (1) {

	$run_id = time();
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
		SELECT alarms.id, alarms.serial,
			alarms.condition, alarms.last_notification, alarms.alarm_state,
			alarms.repeat, alarms.alarm_count, alarms.exp_backoff_enabled,
			alarms.snooze, alarms.default_snooze,
			alarms.snooze_auth_key, alarms.sms_notification,
			alarms.down_message, alarms.up_message
		FROM alarms
		WHERE alarms.enabled
	]);

	$sth->execute;

	while (my $alarm = $sth->fetchrow_hashref) {

		my $msth = $dbh->prepare(qq[
			SELECT info, valve_status, valve_installed
			FROM meters
			WHERE serial = ?
			LIMIT 1
		]);

		$msth->execute($alarm->{serial});
		$alarm->{meter} = $msth->fetchrow_hashref || {};

		evaluate_alarm($alarm, $run_id);
	}
}

# --------------------------
# EVALUATE ALARM
# --------------------------
sub evaluate_alarm {
	my ($alarm, $run_id) = @_;

	my $serial = $alarm->{serial};

	my $snooze_auth_key = $alarm->{snooze_auth_key} || generate_snooze_key();
	my $quoted_snooze_auth_key = $dbh->quote($snooze_auth_key);

	my $condition    = $alarm->{condition};
	my $down_message = fill_template($alarm->{down_message} || 'alarm', $alarm, $snooze_auth_key);
	my $up_message   = fill_template($alarm->{up_message}   || 'normal', $alarm, $snooze_auth_key);

	log_debug("raw condition: $condition", {
		-custom_tag => "ALARM:$run_id:$alarm->{serial}"
	});

	my $closed_status = check_delayed_valve_closed($serial);

	if (defined $closed_status) {
		$condition =~ s/\$closed/$closed_status/g;
	}

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

		log_debug("[eval] result=$eval_alarm_state condition=$condition", {
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
# VALVE LOGIC (UNCHANGED)
# --------------------------
sub check_delayed_valve_closed {
	my ($serial) = @_;

	my $sth = $dbh->prepare("SELECT valve_status, valve_installed FROM meters WHERE serial = ?");
	$sth->execute($serial);
	my ($status, $installed) = $sth->fetchrow_array;

	my $key = "valve:$serial:closed_since";

	unless ($installed && $status =~ /close/i) {
		$redis->del($key);
		return 0;
	}

	my $now = time();
	my $closed_since = $redis->get($key);

	if (!defined $closed_since || $closed_since eq '') {
		$redis->set($key, $now);
		return undef;
	}

	return (($now - $closed_since) >= VALVE_CLOSE_DELAY) ? 1 : undef;
}

# --------------------------
# VARIABLE RESOLVER (3-LAYER MODEL)
# --------------------------
sub interpolate_variables {
	my ($text, $alarm) = @_;
	my $serial = $alarm->{serial};

	log_debug("[interpolate_variables run_id=$run_id] BEFORE: $text", {
		-custom_tag => "VAR:$run_id:$alarm->{serial}"
	});

	my @vars = ($text =~ /\$(\w+)/g);

	foreach my $var (@vars) {

		my $value = resolve_var($var, $alarm, $run_id);

		log_debug("[interpolate_variables run_id=$run_id] var=\$$var value=" . (defined $value ? $value : 'undef'), {
			-custom_tag => "VAR:$run_id:$alarm->{serial}:$var"
		});

		$value = 0 if !defined $value || $value eq '';

		# Format ONLY numeric values for SMS output
		if ($value =~ /^-?\d+(\.\d+)?$/) {
			$value = sprintf("%.2f", $value);
		}

		$text =~ s/\$$var\b/$value/g;
	}

	log_debug("[interpolate_variables run_id=$run_id] AFTER: $text", {
		-custom_tag => "VAR:$run_id:$alarm->{serial}"
	});

	return $text;
}

sub resolve_var {
	my ($var, $alarm, $run_id) = @_;
	my $serial = $alarm->{serial};

	log_debug("[resolve_var run_id=$run_id][serial=$serial] START var=$var", {
		-custom_tag => "VAR:$run_id:$serial"
	});

	# --------------------------
	# DB FIELDS
	# --------------------------
	if ($var eq 'info' || $var eq 'valve_status' || $var eq 'valve_installed') {

		my $val = $alarm->{meter}{$var};

		log_debug("[resolve_var run_id=$run_id][serial=$serial] DB FIELD var=$var value=" . (defined $val ? $val : 'undef'), {
			-custom_tag => "VAR:$run_id:$serial"
		});

		return $val;
	}

	if ($var eq 'serial') {
		return $serial;
	}

	# --------------------------
	# SYSTEM
	# --------------------------
	if ($var eq 'offline') {

		my $sth = $dbh->prepare("SELECT last_updated FROM meters WHERE serial = ?");
		$sth->execute($serial);
		my ($lu) = $sth->fetchrow_array;

		my $val = time() - ($lu || time());

		log_debug("[resolve_var][serial=$serial] SYSTEM offline last_updated=" . ($lu // 'undef') . " value=$val", {
			-custom_tag => "VAR:$run_id:$serial"
		});

		return $val;
	}

	if ($var eq 'closed') {
		my $val = check_delayed_valve_closed($serial);

		log_debug("[resolve_var][serial=$serial] SYSTEM closed value=" . (defined $val ? $val : 'undef'), {
			-custom_tag => "VAR:$run_id:$serial"
		});

		return $val;
	}

	# --------------------------
	# REDIS + EMA
	# --------------------------
	my $redis_key = "sensor:$serial:$var:last_value";
	my $ema_key   = "sensor:$serial:$var:ema";

	# per-alarm EMA cache
	my $alarm_cache_key = "alarm:$alarm->{id}:$serial:$var:ema";

	my $cached = $redis->get($alarm_cache_key);
	my $ttl    = $redis->ttl($alarm_cache_key);

	if (defined $cached && $ttl > 0) {

		log_debug("CACHE HIT value=$cached ttl=$ttl run_id=$run_id", {
			-custom_tag => "EMA:$run_id:$serial:$var"
		});

		return $cached;
	}
	log_debug("[resolve_var][serial=$serial] REDIS keys redis_key=$redis_key ema_key=$ema_key");

	my $val = $redis->get($redis_key);

	log_debug("[resolve_var][serial=$serial] REDIS last_value=" . (defined $val ? $val : 'undef'));

	# fallback to DB if Redis empty
	if (!defined $val) {
		log_debug("Redis MISS -> DB fallback", {
			-custom_tag => "EMA:$run_id:$serial:$var"
		});

		my $sth = $dbh->prepare(qq[
			SELECT `$var`
			FROM samples_cache
			WHERE serial = ?
			ORDER BY unix_time DESC
			LIMIT 1
		]);

		$sth->execute($serial);
		($val) = $sth->fetchrow_array;

		log_debug("[resolve_var][serial=$serial] DB fallback value=" . (defined $val ? $val : 'undef'));
	}

	return undef unless defined $val;

	my $prev = $redis->get($ema_key);

	log_debug("[resolve_var][serial=$serial] EMA prev=" . (defined $prev ? $prev : 'undef'));

	# initialize EMA
	my $new_ema;

	if (!defined $prev) {

		$new_ema = $val;
		$redis->set($ema_key, $val);

		log_debug("EMA INIT val=$val ema=$val", {
			-custom_tag => "EMA:$run_id:$serial:$var"
		});

	} else {

		my $diff = abs($val - $prev);
		my $threshold = ($prev != 0) ? abs($prev) * (THRESHOLD_PERCENT / 100) : 0;

		my $action = ($diff <= $threshold) ? "HOLD" : "UPDATE";

		log_debug("EMA DECISION val=$val prev=$prev diff=$diff threshold=$threshold action=$action", {
			-custom_tag => "EMA:$run_id:$serial:$var"
		});

		if ($diff <= $threshold) {

			$new_ema = $prev;

		} else {

			$new_ema = (EMA_ALPHA * $val) + ((1 - EMA_ALPHA) * $prev);
			$redis->set($ema_key, $new_ema);
		}

		log_debug("EMA OUTPUT value=$new_ema", {
			-custom_tag => "EMA:$run_id:$serial:$var"
		});
	}

	my $out = sprintf("%.2f", $new_ema) + 0;

	# store per-alarm cache
	$redis->set($alarm_cache_key, $out);
	$redis->expire($alarm_cache_key, 70);  # TTL matches loop cycle (~60s)

	log_debug("END final_value=$out", {
		-custom_tag => "EMA:$run_id:$serial:$var"
	});

	return $out;
}

# --------------------------
# ALARM HANDLER
# --------------------------
sub handle_alarm {
	my ($alarm, $state, $down, $up, $key) = @_;

	my $id = $dbh->quote($alarm->{id});
	my $now = time();

	if ($state) {

		if ($alarm->{alarm_state} == 0) {

			sms_send($alarm->{sms_notification}, $down);

			$dbh->do(qq[
				UPDATE alarms
				SET alarm_state=1,
					last_notification=$now,
					alarm_count=1,
					snooze_auth_key=$key
				WHERE id=$id
			]);
		}

	} else {

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

__END__
