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
use constant VALVE_CLOSE_DELAY => 600;  # 10 minutes
use constant INITIAL_NO_BACKOFF => 2;

$| = 1;

my $script_name = basename($0 . ".pl");

# Redis
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
	log_info("SIGTERM received, shutting down...");
	$shutdown_requested = 1;
};

$SIG{INT} = sub {
	log_info("SIGINT received, shutting down...");
	$shutdown_requested = 1;
};

# MAIN LOOP
while (1) {
	process_alarms();
	last if $shutdown_requested;
	sleep 60;
}

# --------------------------
# PROCESS ALARMS
# --------------------------
sub process_alarms {

	my $sth = $dbh->prepare(qq[
		SELECT alarms.id, alarms.serial, meters.info, meters.last_updated,
			alarms.condition, alarms.last_notification, alarms.alarm_state,
			alarms.repeat, alarms.alarm_count, alarms.exp_backoff_enabled,
			alarms.snooze, alarms.default_snooze,
			alarms.snooze_auth_key, alarms.sms_notification,
			alarms.down_message, alarms.up_message
		FROM alarms
		JOIN meters ON alarms.serial = meters.serial
		WHERE alarms.enabled
	]);

	$sth->execute;

	while (my $alarm = $sth->fetchrow_hashref) {
		evaluate_alarm($alarm);
	}
}

# --------------------------
# EVALUATE ALARM
# --------------------------
sub evaluate_alarm {
	my ($alarm) = @_;

	my $serial = $alarm->{serial};

	my $snooze_auth_key = $alarm->{snooze_auth_key} || generate_snooze_key();
	my $quoted_snooze_auth_key = $dbh->quote($snooze_auth_key);

	my $condition    = $alarm->{condition};
	my $down_message = fill_template($alarm->{down_message} || 'alarm', $alarm, $snooze_auth_key);
	my $up_message   = fill_template($alarm->{up_message}   || 'normal', $alarm, $snooze_auth_key);

	log_debug("RAW condition: $condition");

	# --------------------------
	# VALVE LOGIC (REDIS ONLY)
	# --------------------------
	my $closed_status = check_delayed_valve_closed($serial);

	# IMPORTANT: do NOT early-return here anymore
	# just substitute safely if available
	if (defined $closed_status) {
		$condition =~ s/\$closed/$closed_status/g;
	}

	# --------------------------
	# VARIABLE INTERPOLATION
	# --------------------------
	$condition = interpolate_variables($condition, $serial);

	log_debug("PARSED condition: $condition");

	my $eval_alarm_state;
	my $quoted_id = $dbh->quote($alarm->{id});

	{
		local $@;
		no strict;
		no warnings;

		$eval_alarm_state = eval $condition;

		if ($@) {
			log_warn("Eval error: $@ | condition: $condition");

			my $err = $dbh->quote($@);

			$dbh->do(qq[
				UPDATE alarms
				SET condition_error = $err
				WHERE id = $quoted_id
			]);

			return;
		}

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

	return interpolate_variables($template, $alarm->{serial});
}

# --------------------------
# VALVE LOGIC (REDIS FIXED)
# --------------------------
sub check_delayed_valve_closed {
	my ($serial) = @_;

	my $sth = $dbh->prepare("SELECT valve_status, valve_installed FROM meters WHERE serial = ?");
	$sth->execute($serial);
	my ($status, $installed) = $sth->fetchrow_array;

	my $key = "valve:$serial:closed_since";

	# not installed or open → reset
	unless ($installed && $status && $status =~ /close/i) {
		$redis->del($key);
		return 0;
	}

	my $now = time();

	my $closed_since = $redis->get($key);

	# first detection
	if (!defined $closed_since || $closed_since eq '') {
		$redis->set($key, $now);
		return undef;
	}

	$closed_since += 0;

	return (($now - $closed_since) >= VALVE_CLOSE_DELAY) ? 1 : undef;
}

# --------------------------
# VARIABLE INTERPOLATION
# --------------------------
sub interpolate_variables {
	my ($text, $serial) = @_;
	my @vars = ($text =~ /\$(\w+)/g);

	foreach my $var (@vars) {

		next if $var =~ /^(id|serial|info|closed|default_snooze|snooze_auth_key)$/;

		if ($var eq 'offline') {
			my $sth = $dbh->prepare("SELECT last_updated FROM meters WHERE serial = ?");
			$sth->execute($serial);
			my ($lu) = $sth->fetchrow_array;
			my $offline = time() - ($lu || time());
			$text =~ s/\$offline/$offline/g;
			next;
		}

		my $redis_key = "sensor:$serial:$var:last_value";
		my $val = $redis->get($redis_key);

		if (!defined $val) {
			my $sth = $dbh->prepare(qq[
				SELECT `$var`
				FROM samples_cache
				WHERE serial = ?
				ORDER BY unix_time DESC
				LIMIT 5
			]);

			$sth->execute($serial);
			my $rows = $sth->fetchall_arrayref;

			if (@$rows) {
				$val = median(map { $_->[0] + 0 } @$rows);
			}
		}

		$val = 0 if !defined $val || $val eq '';
		$text =~ s/\$$var/$val/g;
	}

	return $text;
}

# --------------------------
# ALARM HANDLER (UNCHANGED)
# --------------------------
sub handle_alarm {
	my ($alarm, $state, $down, $up, $key) = @_;

	my $id = $dbh->quote($alarm->{id});
	my $now = time();

	my $count = $alarm->{alarm_count} || 0;

	if ($state) {

		if ($alarm->{alarm_state} == 0) {

			sms_send($alarm->{sms_notification}, $down);

			$dbh->do(qq[
				UPDATE alarms SET alarm_state=1, last_notification=$now, alarm_count=1,
				snooze_auth_key=$key WHERE id=$id
			]);

		}

	} else {

		if ($alarm->{alarm_state} == 1) {

			sms_send($alarm->{sms_notification}, $up);

			$dbh->do(qq[
				UPDATE alarms SET alarm_state=0, alarm_count=0, snooze=0,
				snooze_auth_key='' WHERE id=$id
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