#!/usr/bin/perl -w

# Perl script to monitor alarms from IoT meters and send SMS notifications
# when certain conditions (like valve closure or abnormal energy usage) are met.

use strict;
use utf8;
use Data::Dumper;
use DBI;
use Statistics::Basic qw(:all);	 # for computing medians
use Math::Random::Secure qw(rand);      # for generating secure random keys
use File::Basename;

use Nabovarme::Db;
use Nabovarme::Utils;

# Constants
use constant VALVE_CLOSE_DELAY => 600;  # 10 minutes delay used in metrics

$| = 1;  # Autoflush STDOUT to ensure logs appear immediately

# Get the basename of the script, without path or .pl extension
my $script_name = basename($0 . ".pl");

# Keep track of when each valve was first seen as "closed"
# key: serial, value: timestamp
my %valve_close_time;

# Connect to MySQL database
my $dbh = Nabovarme::Db->my_connect or log_die("Can't connect to DB: $!");
$dbh->{'mysql_auto_reconnect'} = 1;

log_info("Connected to DB");

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

	# Print the raw condition before any variable replacement
	log_debug("raw condition for serial " . $serial . ", id " . $alarm->{id} . ": " . $condition);

	# Replace $closed with calculated status (based on valve being closed > 5 min)
	my $closed_status = check_delayed_valve_closed($alarm->{serial});
	# Skip evaluation entirely if in grace period
	return if not defined $closed_status;
	
	$condition =~ s/\$closed/$closed_status/;

	# Interpolate other variables from DB/sample data
	$condition = interpolate_variables($condition, $serial);

	# Print the final parsed condition to be evaluated
	log_debug("parsed condition for serial " . $serial . ", id " . $alarm->{id} . ": " . $condition);

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
			 log_warn("Error parsing condition for serial " . $serial . ": " . $condition . ", error: " . $error);

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

# Returns 1 if valve has been closed long enough (VALVE_CLOSE_DELAY)
# Returns 0 if currently open or not installed
# Returns undef during grace period to prevent SMS/actions
sub check_delayed_valve_closed {
	my ($serial) = @_;
	
	# Fetch current valve status from DB
	my $sth = $dbh->prepare("SELECT valve_status, valve_installed FROM meters WHERE serial = ?");
	$sth->execute($serial);
	my ($status, $valve_installed) = $sth->fetchrow_array;

	# If valve not installed or currently open, reset timer and return 0
	unless ($valve_installed && $status =~ /close/i) {
		delete $valve_close_time{$serial};
		return 0;
	}

	# Current time
	my $now = time();

	# Start timer if this is the first detection of closure
	if (!exists $valve_close_time{$serial}) {
		$valve_close_time{$serial} = $now;
		return undef;  # Grace period: skip evaluation/SMS
	}

	# Return 1 only if valve has been closed long enough
	return ($now - $valve_close_time{$serial} >= VALVE_CLOSE_DELAY) ? 1 : undef;
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
		$static_vars{offline}	= time() - ($row->{last_updated} || time());
		$static_vars{info}	   = $row->{info} || '';
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

	# Initialize alarm_count if undefined
	my $count = $alarm->{alarm_count} || 0;

	# Determine if exponential backoff should be used
	my $use_backoff = 0;
	if ($alarm->{exp_backoff_enabled} && $alarm->{repeat} < 86400) {
		$use_backoff = 1;  # only allow backoff for repeats < 24h
	}

	if ($state) {
		if ($alarm->{alarm_state} == 0) {
			# First time alarm triggered
			sms_send($alarm->{sms_notification}, $down_message);
			$count = 1;  # first notification

			$dbh->do(qq[
				UPDATE alarms
				SET last_notification = $now,
					alarm_state = 1,
					snooze_auth_key = $quoted_snooze_auth_key,
					alarm_count = $count
				WHERE id = $quoted_id
			]);

			log_info("Serial " . $alarm->{serial} . ": down (count=1)");

		} elsif ($alarm->{repeat}) {
			# Calculate interval
			my $interval;
			if ($use_backoff) {
				# Ensure first interval uses count=1 to avoid halving repeat
				my $backoff_count = $count || 1;

				# Exponential backoff: repeat * 2^(count-1)
				$interval = $alarm->{repeat} * (2 ** ($backoff_count - 1));

				# Cap at 24h to ensure max 1 SMS per day for small repeats
				$interval = 86400 if $interval > 86400;
			} else {
				# Fixed repeat interval (repeat >= 24h or backoff disabled)
				$interval = $alarm->{repeat};
			}

			if (($alarm->{last_notification} + $interval + $alarm->{snooze}) < $now) {
				sms_send($alarm->{sms_notification}, $down_message);
				$count++;  # increment notification count

				$dbh->do(qq[
					UPDATE alarms
					SET last_notification = $now,
						alarm_state = 1,
						snooze = 0,
						snooze_auth_key = $quoted_snooze_auth_key,
						alarm_count = $count
					WHERE id = $quoted_id
				]);

				log_info("Serial " . $alarm->{serial} . ": down repeat (count=$count, interval=$interval sec, backoff=" . ($use_backoff ? "enabled" : "disabled") . ")");
			}
		}

	} else {
		if ($alarm->{alarm_state} == 1) {
			# Alarm cleared — reset count
			sms_send($alarm->{sms_notification}, $up_message);

			$dbh->do(qq[
				UPDATE alarms
				SET last_notification = $now,
					alarm_state = 0,
					snooze = 0,
					snooze_auth_key = '',
					alarm_count = 0
				WHERE id = $quoted_id
			]);

			log_info("Serial " . $alarm->{serial} . ": up (count reset)");
		}
	}
}

# Send SMS to all numbers in the provided field
sub sms_send {
	my ($recipient, $message) = @_;
	return unless $recipient;

	my @recipients = ($recipient =~ /\d+/g);
	for my $r (@recipients) {
		log_info("Sending SMS to 45$r: $message", { -custom_tag => 'SMS' });
		my $ok = send_notification($r, $message);
		unless ($ok) {
			log_warn("Failed to send SMS to 45$r", { -custom_tag => 'SMS' });
		}
	}
}

# Generate a secure 8-byte hex key for snoozing
sub generate_snooze_key {
	return join('', map { sprintf("%02x", int rand(256)) } 1..8);
}


__END__
