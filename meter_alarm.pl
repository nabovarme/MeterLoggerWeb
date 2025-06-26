#!/usr/bin/perl -w

use strict;
use Data::Dumper;
use DBI;
use Statistics::Basic qw(:all);
use Math::Random::Secure qw(rand);
use Config;

use lib qw(/etc/apache2/perl);
use Nabovarme::Db;

use constant VALVE_CLOSE_DELAY => 600;

$| = 1;	# Autoflush STDOUT

my $dbh = Nabovarme::Db->my_connect or die "Can't connect to DB: $!";
$dbh->{'mysql_auto_reconnect'} = 1;

print "connected to db\n";

while (1) {
	process_alarms();
	sleep 60;
}

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

sub evaluate_alarm {
	my ($alarm) = @_;

	my $serial = $alarm->{serial};
	my $quoted_serial = $dbh->quote($serial);

	my $offline = time() - $alarm->{last_updated};

	my $snooze_auth_key = $alarm->{snooze_auth_key} || generate_snooze_key();
	my $quoted_snooze_auth_key = $dbh->quote($snooze_auth_key);

	my $condition = $alarm->{condition};
	my $down_message = fill_template($alarm->{down_message} || 'alarm', $alarm, $snooze_auth_key);
	my $up_message   = fill_template($alarm->{up_message}   || 'normal', $alarm, $snooze_auth_key);

	$condition = interpolate_variables($condition, $serial);

	print "checking condition for serial $serial, id $alarm->{id}: $condition\n";
	# Safely evaluate the dynamic Perl expression in $condition without strict or warnings.
	# Outer eval catches runtime errors; inner eval executes the actual condition.
	my $eval_alarm_state = eval { no strict; no warnings; eval $condition };

	my $quoted_id = $dbh->quote($alarm->{id});

	if ($@) {
		warn "error parsing condition for serial $serial: $condition, error: $@";

		my $quoted_error = $dbh->quote($@);
		$dbh->do(qq[
			UPDATE alarms
			SET condition_error = $quoted_error
			WHERE id = $quoted_id
		]);

		# Stop processing this alarm if the condition failed to evaluate.
		# The error has been logged in the database, so we safely exit to avoid acting on invalid logic.
		return;
	} else {
		# Clear previous error if condition now evaluates successfully
		$dbh->do(qq[
			UPDATE alarms
			SET condition_error = NULL
			WHERE id = $quoted_id
		]);
	}

	handle_alarm($alarm, $eval_alarm_state, $down_message, $up_message, $quoted_snooze_auth_key);
}

sub fill_template {
	my ($template, $alarm, $snooze_auth_key) = @_;

	$template =~ s/\$snooze_auth_key/$snooze_auth_key/g;
	$template =~ s/\$default_snooze/$alarm->{default_snooze}/g;
	$template =~ s/\$serial/$alarm->{serial}/g;
	$template =~ s/\$id/$alarm->{id}/g;

	return interpolate_variables($template, $alarm->{serial});
}

sub interpolate_variables {
	my ($text, $serial) = @_;
	my @vars = ($text =~ /\$(\w+)/g);

	my %static_vars;

	# Preload commonly used meter fields
	my $sth_meter = $dbh->prepare(qq[
		SELECT last_updated, info, valve_status, valve_installed
		FROM meters
		WHERE serial = ?
	]);
	$sth_meter->execute($serial);
	if (my $row = $sth_meter->fetchrow_hashref) {
		$static_vars{offline}         = time() - ($row->{last_updated} || time());
		$static_vars{info}            = $row->{info} || '';
		$static_vars{valve_status}    = $dbh->quote($row->{valve_status} || '');
		$static_vars{valve_installed} = $row->{valve_installed} + 0;  # force numeric
	}

	foreach my $var (@vars) {
		# Static fields
		if (exists $static_vars{$var}) {
			my $val = $static_vars{$var};
			$val =~ s/"/\\"/g;
			$text =~ s/\$$var/$val/g;
			next;
		}

		# volume_day or energy_day as delta over 24h
		if ($var eq 'volume_day' or $var eq 'energy_day') {
			my $column = $var eq 'volume_day' ? 'volume' : 'energy';
			my $since = time() - 86400 - VALVE_CLOSE_DELAY;

			# Get earliest and latest values within the last 24 hours
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

		# Skip known unsupported vars
		next if $var =~ /^(id|serial|default_snooze|snooze_auth_key)$/;

		# Default: median of last 5 samples
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

sub handle_alarm {
	my ($alarm, $state, $down_message, $up_message, $quoted_snooze_auth_key) = @_;
	my $quoted_id = $dbh->quote($alarm->{id});

	my $now = time();
	if ($state) {
		if ($alarm->{alarm_state} == 0) {
			sms_send($alarm->{sms_notification}, $down_message);
			$dbh->do(qq[UPDATE alarms
						SET
							last_notification = $now,
							alarm_state = 1,
							snooze_auth_key = $quoted_snooze_auth_key
						WHERE id = $quoted_id]);
			print "serial $alarm->{serial}: down\n";
		}
		elsif ($alarm->{repeat} && (($alarm->{last_notification} + $alarm->{repeat} + $alarm->{snooze}) < time())) {
			sms_send($alarm->{sms_notification}, $down_message);
			$dbh->do(qq[UPDATE alarms
						SET last_notification = $now,
							alarm_state = 1,
							snooze = 0,
							snooze_auth_key = $quoted_snooze_auth_key 
						WHERE id = $quoted_id]);
			print "serial $alarm->{serial}: down repeat\n";
		}
	}
	else {
		if ($alarm->{alarm_state} == 1) {
			sms_send($alarm->{sms_notification}, $up_message);
			$dbh->do(qq[UPDATE alarms
						SET last_notification = $now,
							alarm_state = 0,
							snooze = 0,
							snooze_auth_key = ''
						WHERE id = $quoted_id]);
			print "serial $alarm->{serial}: up\n";
		}
	}
}

sub sms_send {
	my ($recipient, $message) = @_;
	return unless $recipient;

	my @recipients = ($recipient =~ /\d+/g);
	for my $r (@recipients) {
		system(qq[/etc/apache2/perl/Nabovarme/bin/smstools_send.pl 45$r "$message"]);
		print qq[/etc/apache2/perl/Nabovarme/bin/smstools_send.pl 45$r "$message"\n];
	}
}

sub generate_snooze_key {
	return join('', map { sprintf("%02x", int rand(256)) } 1..8);
}

__END__
