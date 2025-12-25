#!/usr/bin/perl -w

use strict;
use warnings;
use Data::Dumper;
use DBI;
use File::Basename;
use Config;

use lib qw( /etc/apache2/perl /opt/local/apache2/perl/ );
use Nabovarme::Db;
use Nabovarme::Utils;

use constant CLOSE_WARNING_TIME => 3 * 24; # 3 days in hours

$| = 1;  # Autoflush STDOUT

# Get the basename of the script, without path or .pl extension
my $script_name = basename($0, ".pl");

debug_print("Starting debug mode...");

my ($dbh, $sth, $d, $energy_remaining, $energy_time_remaining, $notification);

# connect to db
if ($dbh = Nabovarme::Db->my_connect) {
	$dbh->{'mysql_auto_reconnect'} = 1;
	print "[", $script_name, "] ", "Connected to DB\n";
} else {
	die "Can't connect to DB: $!";
}

while (1) {
	$sth = $dbh->prepare(qq[
		SELECT `serial`, info, min_amount, valve_status, valve_installed,
			   sw_version, email_notification, sms_notification,
			   close_notification_time, notification_state, notification_sent_at,
			   time_remaining_hours
		FROM meters
		WHERE enabled
		  AND type = 'heat'
		  AND (email_notification OR sms_notification)
	]);
	$sth->execute or warn "[", $script_name, "] " . $DBI::errstr;

	while ($d = $sth->fetchrow_hashref) {

		my $quoted_serial = $dbh->quote($d->{serial});

		# get latest estimates
		my $est = Nabovarme::Utils::estimate_remaining_energy($dbh, $d->{serial});

		$energy_remaining      = ($est->{kwh_remaining} || 0) - ($d->{min_amount} || 0);
		$energy_time_remaining = $est->{time_remaining_hours};
		my $time_remaining_string = $est->{time_remaining_hours_string};

		# get paid kWh and avg energy last day
		my $paid_kwh = sprintf("%.2f", $est->{paid_kwh} || 0);
		my $avg_energy_last_day = sprintf("%.2f", $est->{avg_energy_last_day} || 0);
		my $energy_remaining_fmt = sprintf("%.2f", $energy_remaining);
		my $time_remaining_fmt = defined $energy_time_remaining ? sprintf("%.2f", $energy_time_remaining) : "N/A";

		# --- Notifications ---
		my $close_warning_threshold = $d->{close_notification_time} || CLOSE_WARNING_TIME;

		# Close warning: state 0 -> 1
		if ($d->{notification_state} == 0) {
			if ((defined $energy_time_remaining && $energy_time_remaining < $close_warning_threshold)
				|| ($energy_remaining <= ($d->{min_amount} + 0.2))) {

				# DEBUG: only when sending notification
				debug_print(
					"Serial: $d->{serial}",
					"State: $d->{notification_state}",
					"Energy remaining: $energy_remaining_fmt kWh",
					"Paid kWh: $paid_kwh kWh",
					"Avg energy last day: $avg_energy_last_day kWh",
					"Time remaining: $time_remaining_fmt h",
					"Notification sent at: " . ($d->{notification_sent_at} || 'N/A')
				);

				# Send notification
				$notification = "close warning: $d->{info} closing soon. $time_remaining_string remaining. ($d->{serial})";
				_send_notification($d->{sms_notification}, $notification);

				$dbh->do(qq[
					UPDATE meters
					SET notification_state = 1,
						notification_sent_at = UNIX_TIMESTAMP()
					WHERE `serial` = $quoted_serial
				]) or warn("[", $script_name, "] ", "DB update failed for serial ", $d->{serial}, ". ", $DBI::errstr);

				print("[", $script_name, "] ", "close warning sent for serial ", $d->{serial});
			}
		}

		# Close notice: state 1 -> 2
		elsif ($d->{notification_state} == 1) {
			if ($energy_remaining <= 0) {

				# DEBUG: only when sending notification
				debug_print(
					"Serial: $d->{serial}",
					"State: $d->{notification_state}",
					"Energy remaining: $energy_remaining_fmt kWh",
					"Paid kWh: $paid_kwh kWh",
					"Avg energy last day: $avg_energy_last_day kWh",
					"Time remaining: $time_remaining_fmt h",
					"Notification sent at: " . ($d->{notification_sent_at} || 'N/A')
				);

				# Send notification
				$notification = "close notice: $d->{info} closed. ($d->{serial})";
				_send_notification($d->{sms_notification}, $notification);

				$dbh->do(qq[
					UPDATE meters
					SET notification_state = 2,
						notification_sent_at = UNIX_TIMESTAMP()
					WHERE `serial` = $quoted_serial
				]) or warn("[", $script_name, "] ", "DB update failed for serial ", $d->{serial}, ". ", $DBI::errstr);

				print("[", $script_name, "] " . "close notice sent for serial " . $d->{serial});
			}
		}

		# Open notice: state 2 -> 0
		elsif ($d->{notification_state} == 2) {
			if (defined $energy_time_remaining && $energy_remaining > 0.2) { # small margin

				# DEBUG: only when sending notification
				debug_print(
					"Serial: $d->{serial}",
					"State: $d->{notification_state}",
					"Energy remaining: $energy_remaining_fmt kWh",
					"Paid kWh: $paid_kwh kWh",
					"Avg energy last day: $avg_energy_last_day kWh",
					"Time remaining: $time_remaining_fmt h",
					"Notification sent at: " . ($d->{notification_sent_at} || 'N/A')
				);

				# Send notification
				$notification = "open notice: $d->{info} open. $time_remaining_string remaining. ($d->{serial})";
				_send_notification($d->{sms_notification}, $notification);

				$dbh->do(qq[
					UPDATE meters
					SET notification_state = 0,
						notification_sent_at = UNIX_TIMESTAMP()
					WHERE `serial` = $quoted_serial
				]) or warn("[", $script_name, "] ", "[ERROR] DB update failed for serial ", $d->{serial}, ". ", $DBI::errstr);

				print("[", $script_name, "] ", "open notice sent for serial ", $d->{serial});
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
		debug_print("45" . $num . ": " . $message);
		system(qq[/etc/apache2/perl/Nabovarme/bin/smstools_send.pl 45$num "$message"]);
	}
}

# --- debug print helper ---
sub debug_print {
	# Only print if debug mode is enabled via environment variable
	return unless ($ENV{ENABLE_DEBUG} || '') =~ /^(1|true)$/i;

	# Print each item on its own line, with script name prefix
	foreach my $line (@_) {
		my $text = defined $line ? $line : '';

		print "[", $script_name, "] ", $text, "\n";
	}
}
