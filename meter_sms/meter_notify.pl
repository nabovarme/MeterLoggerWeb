#!/usr/bin/perl -w

use strict;
use warnings;
use Data::Dumper;
use DBI;
use Config;

use lib qw( /etc/apache2/perl /opt/local/apache2/perl/ );
use Nabovarme::Db;
use Nabovarme::Utils;

use constant CLOSE_WARNING_TIME => 3 * 24; # 3 days in hours

debug_print("Starting debug mode...");

my ($dbh, $sth, $d, $energy_remaining, $energy_time_remaining, $notification);

# connect to db
if ($dbh = Nabovarme::Db->my_connect) {
	$dbh->{'mysql_auto_reconnect'} = 1;
	debug_print("Connected to DB");
} else {
	die "Can't connect to DB: $!";
}

while (1) {
	$sth = $dbh->prepare(qq[
		SELECT serial, info, min_amount, valve_status, valve_installed,
			   sw_version, email_notification, sms_notification,
			   close_notification_time, notification_state, notification_sent_at,
			   time_remaining_hours
		FROM meters
		WHERE enabled
		  AND type = 'heat'
		  AND (email_notification OR sms_notification)
	]);
	$sth->execute;

	while ($d = $sth->fetchrow_hashref) {

		my $quoted_serial = $dbh->quote($d->{serial});

		# get latest estimates
		my $est = Nabovarme::Utils::estimate_remaining_energy($dbh, $d->{serial});

		$energy_remaining      = ($est->{kwh_remaining} || 0) - ($d->{min_amount} || 0);
		$energy_time_remaining = $est->{time_remaining_hours};
		my $time_remaining_string = $est->{time_remaining_hours_string};

		# --- DEBUG LOG ---
		debug_print("[DEBUG] serial=$d->{serial} state=$d->{notification_state} energy_remaining=$energy_remaining time_remaining=$energy_time_remaining notification_sent_at=$d->{notification_sent_at}");

		# --- Notifications ---
		if ($d->{notification_state} == 0) {
			if (defined $energy_time_remaining && $energy_time_remaining < ($d->{close_notification_time} || CLOSE_WARNING_TIME)) {
				$notification = "[DEBUG] close warning: $d->{info} closing in $time_remaining_string. ($d->{serial})";
				_send_notification($d->{sms_notification}, $notification);

				$dbh->do(qq[
					UPDATE meters
					SET notification_state = 1,
						notification_sent_at = UNIX_TIMESTAMP()
					WHERE serial = $quoted_serial
				]) or debug_print($!);
				debug_print("[INFO] close warning sent for serial #$d->{serial}, energy_remaining=$energy_remaining");
			}
		}
		elsif ($d->{notification_state} == 1) {
			if ($energy_remaining <= 0) {
				$notification = "[DEBUG] close notice: $d->{info} closed. ($d->{serial})";
				_send_notification($d->{sms_notification}, $notification);

				$dbh->do(qq[
					UPDATE meters SET notification_state = 2, notification_sent_at = UNIX_TIMESTAMP() WHERE serial = $quoted_serial
				]) or debug_print($!);
				debug_print("[INFO] close notice sent for serial #$d->{serial}, energy_remaining=$energy_remaining");
			}
		}
		elsif ($d->{notification_state} == 2) {
			if (defined $energy_time_remaining && $energy_remaining > 0.2) { # small margin for hysteresis
				$notification = "[DEBUG] open notice: $d->{info} open. $time_remaining_string remaining. ($d->{serial})";
				_send_notification($d->{sms_notification}, $notification);

				$dbh->do(qq[
					UPDATE meters SET notification_state = 0, notification_sent_at = UNIX_TIMESTAMP() WHERE serial = $quoted_serial
				]) or debug_print($!);
				debug_print("[INFO] open notice sent for serial #$d->{serial}, energy_remaining=$energy_remaining");
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
		debug_print("[SMS] 45$num: $message");
		system(qq[/etc/apache2/perl/Nabovarme/bin/smstools_send.pl 45$num "$message"]);
	}
}

# --- debug print helper ---
sub debug_print {
	my ($msg) = @_;
	print "$msg\n" if ($ENV{ENABLE_DEBUG} // '') =~ /^(1|true)$/i;
}
