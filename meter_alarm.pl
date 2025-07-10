#!/usr/bin/perl -w

# Perl script to monitor alarms from IoT meters and send SMS notifications
# when certain conditions (like valve closure or abnormal energy usage) are met.

use strict;
use Data::Dumper;
use DBI;
use Statistics::Basic qw(:all);         # for computing medians
use Math::Random::Secure qw(rand);      # for generating secure random keys
use Config;

# Custom library path for database connection
use lib qw(/etc/apache2/perl);
use Nabovarme::Db;

# Constants
use constant VALVE_CLOSE_DELAY => 600;  # 10 minutes delay used in metrics

$| = 1;  # Autoflush STDOUT to ensure logs appear immediately

# Keep track of when each valve was first seen as "closed"
# key: serial, value: timestamp
my %valve_close_time;

# Connect to MySQL database
my $dbh = Nabovarme::Db->my_connect or die "Can't connect to DB: $!";
$dbh->{'mysql_auto_reconnect'} = 1;

print "connected to db\n";

# Main loop: run every 60 seconds
while (1) {
	process_alarms();
	sleep 60;
}

# Fetch all enabled alarms and evaluate each one
sub process_alarms {
	my $sth = $dbh->prepare(qq[
		SELECT alarms.id, alarms.serial, meters.info, meters.last_updated,
			alarms.condition, alarms.last_notification, alarms.alarm_state,
			alarms.repeat, alarms.snooze, alarms.default_snooze,
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

# Evaluate a single alarm condition
sub evaluate_alarm {
	my ($alarm) = @_;

	my $serial = $alarm->{serial};
	my $quoted_serial = $dbh->quote($serial);

	# 'offline' is calculated as seconds since last update
	my $offline = time() - $alarm->{last_updated};

	# If no snooze key exists yet, generate one
	my $snooze_auth_key = $alarm->{snooze_auth_key} || generate_snooze_key();
	my $quoted_snooze_auth_key = $dbh->quote($snooze_auth_key);

	# Prepare messages and interpolate template variables
	my $condition     = $alarm->{condition};
	my $down_message  = fill_template($alarm->{down_message} || 'alarm', $alarm, $snooze_auth_key);
	my $up_message    = fill_template($alarm->{up_message}   || 'normal', $alarm, $snooze_auth_key);

	# Fill dynamic variables into the condition string
	$condition = interpolate_variables($condition, $serial);

	# Replace $leak with calculated status (based on valve being closed > 5 min)
	my $leak_status = check_delayed_valve_closed($alarm->{serial});
	$condition =~ s/\$leak/$leak_status/;

	print "checking condition for serial $serial, id $alarm->{id}: $condition\n";

	# Evaluate the condition safely
	my $eval_alarm_state;
	my $quoted_id = $dbh->quote($alarm->{id});
	{
		local $@;
		no strict;
		no warnings;
		$eval_alarm_state = eval $condition;

		if ($@) {
			# Log condition parse errors in DB
			my $error = $@;
			warn "error parsing condition for serial $serial: $condition, error: $error";

			my $quoted_error = $dbh->quote($error);
			$dbh->do(qq[
				UPDATE alarms
				SET condition_error = $quoted_error
				WHERE id = $quoted_id
			]);
			return;
		} else {
			# Clear any previous condition error if current eval succeeded
			$dbh->do(qq[
				UPDATE alarms
				SET condition_error = NULL
				WHERE id = $quoted_id
			]);
		}
	}

	# Take action based on evaluated result
	handle_alarm($alarm, $eval_alarm_state, $down_message, $up_message, $quoted_snooze_auth_key);
}

# Interpolate alarm message templates with actual values
sub fill_template {
	my ($template, $alarm, $snooze_auth_key) = @_;

	$template =~ s/\$snooze_auth_key/$snooze_auth_key/g;
	$template =~ s/\$default_snooze/$alarm->{default_snooze}/g;
	$template =~ s/\$serial/$alarm->{serial}/g;
	$template =~ s/\$id/$alarm->{id}/g;

	return interpolate_variables($template, $alarm->{serial});
}

# Returns 1 if valve has been closed for >5 minutes, 0 otherwise
sub check_delayed_valve_closed {
	my ($serial) = @_;

	my $sth = $dbh->prepare("SELECT valve_status FROM meters WHERE serial = ?");
	$sth->execute($serial);
	my ($status) = $sth->fetchrow_array;

	my $now = time();
	if ($status eq 'closed') {
		if (!exists $valve_close_time{$serial}) {
			# Start timer on first closure detection
			$valve_close_time{$serial} = $now;
			return 0;
		}
		if ($now - $valve_close_time{$serial} >= VALVE_CLOSE_DELAY) {
			# Closed long enough — trigger leak detection
			return 1;
		} else {
			return 0;
		}
	} else {
		# Valve reopened — reset timer
		delete $valve_close_time{$serial};
		return 0;
	}
}

# Replaces $variables in a string with values from meter/sample data
sub interpolate_variables {
	my ($text, $serial) = @_;
	my @vars = ($text =~ /\$(\w+)/g);

	my %static_vars;

	# Fetch some common fields from meters table
	my $sth_meter = $dbh->prepare(qq[
		SELECT last_updated, info, valve_status, valve_installed
		FROM meters
		WHERE serial = ?
	]);
	$sth_meter->execute($serial);
	if (my $row = $sth_meter->fetchrow_hashref) {
		$static_vars{offline}        = time() - ($row->{last_updated} || time());
		$static_vars{info}           = $row->{info} || '';
		$static_vars{valve_status}   = $dbh->quote($row->{valve_status} || '');
		$static_vars{valve_installed}= $row->{valve_installed} + 0;  # force numeric
	}

	foreach my $var (@vars) {
		if (exists $static_vars{$var}) {
			my $val = $static_vars{$var};
			$val =~ s/"/\\"/g;
			$text =~ s/\$$var/$val/g;
			next;
		}

		# volume_day / energy_day calculated over last 24h - delay window
		if ($var eq 'volume_day' or $var eq 'energy_day') {
			my $column = $var eq 'volume_day' ? 'volume' : 'energy';
			my $since = time() - 86400 - VALVE_CLOSE_DELAY;

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

			# Get latest sample
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
			$delta = 0 if $delta < 0;  # protect against counter resets

			$text =~ s/\$$var/$delta/g;
			next;
		}

		# Skip alarm system fields not tied to sample data
		next if $var =~ /^(id|serial|default_snooze|snooze_auth_key)$/;

		# Default behavior: median of last 5 values from samples_cache
		my $quoted_var = '`' . $var . '`';
		my $sth = $dbh->prepare(qq[
			SELECT $quoted_var
			FROM samples_cache
			WHERE serial = ?
			ORDER BY unix_time DESC
			LIMIT 5
		]);
		$sth->execute($serial);
		my $values = $sth->fetchall_arrayref;
		if (@$values) {
			my $median_val = median(map { $_->[0] + 0.0 } @$values) + 0.0;
			$text =~ s/\$$var/$median_val/g;
		}
	}

	return $text;
}

# Send SMS based on alarm state (up/down)
sub handle_alarm {
	my ($alarm, $state, $down_message, $up_message, $quoted_snooze_auth_key) = @_;
	my $quoted_id = $dbh->quote($alarm->{id});
	my $now = time();

	if ($state) {
		if ($alarm->{alarm_state} == 0) {
			# First time alarm triggered
			sms_send($alarm->{sms_notification}, $down_message);
			$dbh->do(qq[
				UPDATE alarms
				SET last_notification = $now,
					alarm_state = 1,
					snooze_auth_key = $quoted_snooze_auth_key
				WHERE id = $quoted_id
			]);
			print "serial $alarm->{serial}: down\n";
		}
		elsif ($alarm->{repeat} && (($alarm->{last_notification} + $alarm->{repeat} + $alarm->{snooze}) < time())) {
			# Repeated notification after snooze period
			sms_send($alarm->{sms_notification}, $down_message);
			$dbh->do(qq[
				UPDATE alarms
				SET last_notification = $now,
					alarm_state = 1,
					snooze = 0,
					snooze_auth_key = $quoted_snooze_auth_key 
				WHERE id = $quoted_id
			]);
			print "serial $alarm->{serial}: down repeat\n";
		}
	}
	else {
		if ($alarm->{alarm_state} == 1) {
			# Condition has cleared — send "back to normal" message
			sms_send($alarm->{sms_notification}, $up_message);
			$dbh->do(qq[
				UPDATE alarms
				SET last_notification = $now,
					alarm_state = 0,
					snooze = 0,
					snooze_auth_key = ''
				WHERE id = $quoted_id
			]);
			print "serial $alarm->{serial}: up\n";
		}
	}
}

# Send SMS to all numbers in the provided field
sub sms_send {
	my ($recipient, $message) = @_;
	return unless $recipient;

	my @recipients = ($recipient =~ /\d+/g);
	for my $r (@recipients) {
		system(qq[/etc/apache2/perl/Nabovarme/bin/smstools_send.pl 45$r "$message"]);
		print qq[/etc/apache2/perl/Nabovarme/bin/smstools_send.pl 45$r "$message"\n];
	}
}

# Generate a secure 8-byte hex key for snoozing
sub generate_snooze_key {
	return join('', map { sprintf("%02x", int rand(256)) } 1..8);
}

__END__
