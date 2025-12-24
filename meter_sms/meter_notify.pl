#!/usr/bin/perl -w

# -----------------------------------------------------------------------------
# Notification State Mapping
#
# 0  - Ready to send close warning
# 1  - Close warning marked to send (in-progress)
# 2  - Close notice marked to send (in-progress)
# 3  - Open notice marked to send (in-progress)
# 4  - Close warning sent
# 5  - Close notice sent
# 6  - Open notice sent
#
# Workflow:
#   0 -> 1 -> 4      Close warning
#   4 -> 2 -> 5      Close notice
#   5 -> 3 -> 6      Open notice
#
# Notes:
# - When sending a notification, the row is first marked as "marked to send"
#   (1,2,3) to prevent duplicate sends if the script crashes.
# - After a successful send, the state is updated to the final "sent" state
#   (4,5,6).
# - This allows safe retries and crash recovery without duplicate notifications.
# -----------------------------------------------------------------------------

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

my $script_name = basename($0, ".pl");

debug_print("Starting debug mode...");

my ($dbh, $sth, $d, $energy_remaining, $energy_time_remaining, $notification);

# connect to db
if ($dbh = Nabovarme::Db->my_connect) {
	$dbh->{'mysql_auto_reconnect'} = 1;
	print "[", $script_name, "] Connected to DB\n";
} else {
	die "Can't connect to DB: $!";
}

# --- state labels for debug output ---
my %state_label = (
	0 => 'Ready to send close warning',
	1 => 'Close warning marked to send (in-progress)',
	2 => 'Close notice marked to send (in-progress)',
	3 => 'Open notice marked to send (in-progress)',
	4 => 'Close warning sent',
	5 => 'Close notice sent',
	6 => 'Open notice sent',
);

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

		# get paid kWh and avg energy last day
		my $paid_kwh = sprintf("%.2f", $est->{paid_kwh} || 0);
		my $avg_energy_last_day = sprintf("%.2f", $est->{avg_energy_last_day} || 0);
		my $energy_remaining_fmt = sprintf("%.2f", $energy_remaining);
		my $time_remaining_fmt = defined $energy_time_remaining ? sprintf("%.2f", $energy_time_remaining) : "N/A";

		debug_print(
			"[DEBUG] Serial: $d->{serial}",
			"        State: $d->{notification_state}",
			"        Energy remaining: $energy_remaining_fmt kWh",
			"        Paid kWh: $paid_kwh kWh",
			"        Avg energy last day: $avg_energy_last_day kWh",
			"        Time remaining: $time_remaining_fmt h",
			"        Notification sent at: ", ($d->{notification_sent_at} || 'N/A')
		);

		# --- Notifications ---
		my $close_warning_threshold = $d->{close_notification_time} || CLOSE_WARNING_TIME;

		# Close warning: state 0 -> 1 -> 4
		if ($d->{notification_state} == 0 || $d->{notification_state} == 1) {
			if ((defined $energy_time_remaining && $energy_time_remaining < $close_warning_threshold)
				|| ($energy_remaining <= ($d->{min_amount} + 0.2))) {

				eval {
					$dbh->{'AutoCommit'} = 0;
					$dbh->{'RaiseError'} = 1;

					my $claimed = $dbh->do(qq[
						UPDATE meters
						SET notification_state = 1, notification_sent_at = UNIX_TIMESTAMP()
						WHERE serial = $quoted_serial
						  AND (notification_state = 0 OR notification_state = 1)
					]);

					if ($claimed) {
						my $msg = "close warning: $d->{info} closing soon. $time_remaining_string remaining. ($d->{serial})";
						_send_notification($d->{sms_notification}, $msg);

						$dbh->do(qq[
							UPDATE meters
							SET notification_state = 4
							WHERE serial = $quoted_serial
						]);
						$dbh->commit;
						debug_print("[INFO] close warning sent for serial $d->{serial}");
					} else {
						$dbh->rollback;
					}
				};
				if ($@) {
					warn "[WARN] Error processing serial $d->{serial}: $@\n";
					eval { $dbh->rollback(); };
				}
			}
		}

		# Close notice: state 4 -> 2 -> 5
		elsif ($d->{notification_state} == 4 || $d->{notification_state} == 2) {
			if ($energy_remaining <= 0) {
				eval {
					$dbh->{'AutoCommit'} = 0;
					$dbh->{'RaiseError'} = 1;

					my $claimed = $dbh->do(qq[
						UPDATE meters
						SET notification_state = 2, notification_sent_at = UNIX_TIMESTAMP()
						WHERE serial = $quoted_serial
						  AND (notification_state = 4 OR notification_state = 2)
					]);

					if ($claimed) {
						my $msg = "close notice: $d->{info} closed. ($d->{serial})";
						_send_notification($d->{sms_notification}, $msg);

						$dbh->do(qq[
							UPDATE meters
							SET notification_state = 5
							WHERE serial = $quoted_serial
						]);
						$dbh->commit;
						debug_print("[INFO] close notice sent for serial $d->{serial}");
					} else {
						$dbh->rollback;
					}
				};
				if ($@) {
					warn "[WARN] Error processing serial $d->{serial}: $@\n";
					eval { $dbh->rollback(); };
				}
			}
		}

		# Open notice: state 5 -> 3 -> 6
		elsif ($d->{notification_state} == 5 || $d->{notification_state} == 3) {
			if (defined $energy_time_remaining && $energy_remaining > 0.2) {
				eval {
					$dbh->{'AutoCommit'} = 0;
					$dbh->{'RaiseError'} = 1;

					my $claimed = $dbh->do(qq[
						UPDATE meters
						SET notification_state = 3, notification_sent_at = UNIX_TIMESTAMP()
						WHERE serial = $quoted_serial
						  AND (notification_state = 5 OR notification_state = 3)
					]);

					if ($claimed) {
						my $msg = "open notice: $d->{info} open. $time_remaining_string remaining. ($d->{serial})";
						_send_notification($d->{sms_notification}, $msg);

						$dbh->do(qq[
							UPDATE meters
							SET notification_state = 6
							WHERE serial = $quoted_serial
						]);
						$dbh->commit;
						debug_print("[INFO] open notice sent for serial $d->{serial}");
					} else {
						$dbh->rollback;
					}
				};
				if ($@) {
					warn "[WARN] Error processing serial $d->{serial}: $@\n";
					eval { $dbh->rollback(); };
				}
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
		debug_print("[SMS] Sending to 45$num: $message");
		my $ok = system(qq[/etc/apache2/perl/Nabovarme/bin/smstools_send.pl 45$num "$message"]) == 0;

		unless ($ok) {
			debug_print("[SMS] Failed to send SMS to 45$num");
		}
	}
}

# --- debug print helper ---
sub debug_print {
	return unless ($ENV{ENABLE_DEBUG} || '') =~ /^(1|true)$/i;
	print "[", $script_name, "] ";
	print map { defined $_ ? $_ : '' } @_;
	print "\n";
}
