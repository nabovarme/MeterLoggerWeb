#!/usr/bin/perl -w

use strict;
use warnings;
use Data::Dumper;
use Sys::Syslog;
use DBI;
use Config;

use lib qw( /etc/apache2/perl /opt/local/apache2/perl/ );
use Nabovarme::Db;
use Nabovarme::Utils;

use constant CLOSE_WARNING_TIME => 3 * 24; # 3 days in hours

openlog($0, "ndelay,pid", "local0");
syslog('info', "starting...");

my ($dbh, $sth, $d, $energy_remaining, $energy_time_remaining, $notification);

# connect to db
if ($dbh = Nabovarme::Db->my_connect) {
	$dbh->{'mysql_auto_reconnect'} = 1;
	syslog('info', "connected to db");
} else {
	syslog('info', "can't connect to db $!");
	die $!;
}

while (1) {
	# fetch all meters that require notifications
	$sth = $dbh->prepare(qq[
		SELECT serial, info, min_amount, valve_status, valve_installed,
			   sw_version, email_notification, sms_notification,
			   close_notification_time, notification_state, notification_sent_at,
			   kwh_remaining, time_remaining_hours
		FROM meters
		WHERE enabled
		  AND type = 'heat'
		  AND (email_notification OR sms_notification)
	]);
	$sth->execute;

	while ($d = $sth->fetchrow_hashref) {

		my $quoted_serial = $dbh->quote($d->{serial});

		# calculate remaining energy
		$energy_remaining = ($d->{kwh_remaining} || 0) - ($d->{min_amount} || 0);

		# use precomputed time_remaining_hours from DB
		$energy_time_remaining = $d->{time_remaining_hours};

		my $time_remaining_string = (!defined $energy_time_remaining || $d->{valve_installed} == 0)
			? '∞'
			: rounded_duration($energy_time_remaining * 3600);

		# --- Notifications ---
		if ($d->{notification_state} == 0) {    # close warning not sent yet
			if (defined $energy_time_remaining && $energy_time_remaining < (($d->{close_notification_time} || CLOSE_WARNING_TIME))) {
				$notification = "Nabovarme $d->{info} closing in $time_remaining_string. ($d->{serial}) https://meterlogger.net/detail_acc.epl?serial=$d->{serial}";
				_send_notification($d->{sms_notification}, $notification);

				$dbh->do(qq[
					UPDATE meters
					SET notification_state = 1,
						notification_sent_at = $energy_remaining
					WHERE serial = $quoted_serial
				]) or warn $!;
				syslog('info', "close warning sent for serial #$d->{serial}, energy_remaining=$energy_remaining");
			}
		}
		elsif ($d->{notification_state} == 1) { # close notice
			if ($energy_remaining <= 0) {
				$notification = "Nabovarme $d->{info} closed. ($d->{serial}) https://meterlogger.net/detail_acc.epl?serial=$d->{serial}";
				_send_notification($d->{sms_notification}, $notification);

				$dbh->do(qq[
					UPDATE meters SET notification_state = 2 WHERE serial = $quoted_serial
				]) or warn $!;
				syslog('info', "close notice sent for serial #$d->{serial}, energy_remaining=$energy_remaining");
			}
			elsif (defined $energy_time_remaining && $energy_remaining > $d->{notification_sent_at}) {
				# send open notice
				$notification = "Nabovarme $d->{info} open. $time_remaining_string remaining. ($d->{serial}) https://meterlogger.net/detail_acc.epl?serial=$d->{serial}";
				_send_notification($d->{sms_notification}, $notification);

				$dbh->do(qq[
					UPDATE meters SET notification_state = 0 WHERE serial = $quoted_serial
				]) or warn $!;
				syslog('info', "open notice sent for serial #$d->{serial}, energy_remaining=$energy_remaining");
			}
		}
		elsif ($d->{notification_state} == 2) { # open notice previously sent
			if (defined $energy_time_remaining && $energy_time_remaining > 0) {
				$notification = "Nabovarme $d->{info} open. $time_remaining_string remaining. ($d->{serial}) https://meterlogger.net/detail_acc.epl?serial=$d->{serial}";
				_send_notification($d->{sms_notification}, $notification);

				$dbh->do(qq[
					UPDATE meters SET notification_state = 0 WHERE serial = $quoted_serial
				]) or warn $!;
				syslog('info', "open notice sent for serial #$d->{serial}, energy_remaining=$energy_remaining");
			}
		}
	}

	sleep 1;
}

# --- helper to send SMS ---
sub _send_notification {
	my ($sms_notification, $message) = @_;
	return unless $sms_notification;

	my @numbers = ($sms_notification =~ /(\d+)(?:,\s?)*/g);
	foreach my $num (@numbers) {
		syslog('info', qq[/etc/apache2/perl/Nabovarme/bin/smstools_send.pl 45$num "$message"]);
		system(qq[/etc/apache2/perl/Nabovarme/bin/smstools_send.pl 45$num "$message"]);
	}
}

sub sig_int_handler {
	die $!;
}
