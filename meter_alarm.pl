#!/usr/bin/perl -w

use strict;
use Data::Dumper;
use DBI;
use Statistics::Basic qw(:all);
use Math::Random::Secure qw(rand);
use Config;

use lib qw(/etc/apache2/perl);
use Nabovarme::Db;

my $dbh = Nabovarme::Db->my_connect or die "Can't connect to DB: $!";
$dbh->{'mysql_auto_reconnect'} = 1;

warn "connected to db";

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

	warn "checking condition for serial $serial, id $alarm->{id}: $condition";
	my $eval_alarm_state = eval 'no strict; ' . $condition;

	if ($@) {
		warn "error parsing condition for serial $serial: $condition, error: $@";
		return;
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

	# Static or directly available variables
	my %static_vars;

	# Preload meter data for offline and info
	my $sth_meter = $dbh->prepare(qq[
		SELECT last_updated, info FROM meters WHERE serial = ?
	]);
	$sth_meter->execute($serial);
	if (my $row = $sth_meter->fetchrow_hashref) {
		$static_vars{offline} = time() - ($row->{last_updated} || time());
		$static_vars{info}    = $row->{info} || '';
	}

	foreach my $var (@vars) {
		# Handle static vars like offline and info
		if (exists $static_vars{$var}) {
			$text =~ s/\$$var/$static_vars{$var}/g;
			next;
		}

		# Skip known unsupported vars
		next if $var =~ /^(id|serial|default_snooze|snooze_auth_key)$/;

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
			warn "serial $alarm->{serial}: down";
		}
		elsif ($alarm->{repeat} && (($alarm->{last_notification} + $alarm->{repeat} + $alarm->{snooze}) < time())) {
			sms_send($alarm->{sms_notification}, $down_message);
			$dbh->do(qq[UPDATE alarms
						SET last_notification = $now,
							alarm_state = 1,
							snooze = 0,
							snooze_auth_key = $quoted_snooze_auth_key 
						WHERE id = $quoted_id]);
			warn "serial $alarm->{serial}: down repeat";
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
			warn "serial $alarm->{serial}: up";
		}
	}
}

sub sms_send {
	my ($recipient, $message) = @_;
	return unless $recipient;

	my @recipients = ($recipient =~ /\d+/g);
	for my $r (@recipients) {
		system(qq[/etc/apache2/perl/Nabovarme/bin/smstools_send.pl 45$r "$message"]);
		warn(qq[/etc/apache2/perl/Nabovarme/bin/smstools_send.pl 45$r "$message"]);
	}
}

sub generate_snooze_key {
	return join('', map { sprintf("%02x", int rand(256)) } 1..8);
}

__END__
