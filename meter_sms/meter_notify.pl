#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
use Data::Dumper;
use DBI;

use Nabovarme::Db;
use Nabovarme::Utils;

$| = 1;  # Autoflush STDOUT
STDOUT->autoflush(1);
STDERR->autoflush(1);

log_warn("Starting debug mode...");

# --- Read messages from environment variables ---
my $UP_MESSAGE             = $ENV{UP_MESSAGE}             || 'Open notice: {info} open. {time_remaining} remaining. ({serial})';
my $DOWN_MESSAGE           = $ENV{DOWN_MESSAGE}           || 'Close notice: {info} closed. ({serial})';
my $CLOSE_WARNING_MESSAGE  = $ENV{CLOSE_WARNING_MESSAGE}  || 'Close warning: {info} closing soon. {time_remaining} remaining. ({serial})';
my $CLOSE_WARNING_TIME     = $ENV{CLOSE_WARNING_TIME}     || 3 * 24; # 3 days in hours

my $HYST = 0.5;
my $CLOSE_THRESHOLD = 1;

my ($dbh, $sth, $d, $energy_remaining, $energy_time_remaining_hours, $notification);

# connect to db
if ($dbh = Nabovarme::Db->my_connect) {
	$dbh->{'mysql_auto_reconnect'} = 1;
	log_info("Connected to DB");
} else {
	log_die("Can't connect to DB: $!");
}

while (1) {
	$sth = $dbh->prepare(qq[
		SELECT 
		m.serial, m.info, m.min_amount, m.valve_status, m.valve_installed,
		m.sw_version, m.email_notification, m.sms_notification,
		ms.close_notification_time, ms.notification_state, ms.last_paid_kwh_marker,
		ms.last_notification_sent_time,
		ms.kwh_remaining, ms.time_remaining_hours, ms.time_remaining_hours_string,
		ms.energy_last_day, ms.avg_energy_last_day, ms.latest_energy, ms.paid_kwh, ms.method
	FROM meters m
	LEFT JOIN meters_state ms ON ms.serial = m.serial
	WHERE m.enabled = 1
		AND m.valve_installed = 1
		AND m.type = 'heat'
		AND (m.email_notification OR m.sms_notification)
	]);
	$sth->execute or log_warn($DBI::errstr);

	while ($d = $sth->fetchrow_hashref) {

		my $quoted_serial = $dbh->quote($d->{serial});

		# Get the latest energy estimates
		my $est = Nabovarme::Utils::estimate_remaining_energy($dbh, $d->{serial});

		$energy_remaining            = ($est->{kwh_remaining} || 0) - ($d->{min_amount} || 0);
		$energy_time_remaining_hours = $est->{time_remaining_hours};
		my $time_remaining_string    = $est->{time_remaining_hours_string};

		# --- Determine if last_paid_kwh_marker or state needs updating ---
		my $new_state = $d->{notification_state};
		my $new_last_paid_kwh_marker = $d->{last_paid_kwh_marker};
		my $update_needed = 0;

		# --- Top-up detection (independent of state) ---
		if (defined $est->{paid_kwh} && $est->{paid_kwh} > ($d->{last_paid_kwh_marker} || 0) + $HYST) {

			# Debug log for sending open notice after top-up
			log_warn(
				"Serial: $d->{serial}",
				"Top-up detected",
				"Paid kWh increased: " . ($d->{last_paid_kwh_marker} || 0) . " → $est->{paid_kwh}",
				"Energy remaining: " . sprintf("%.2f", $energy_remaining) . " kWh",
				"Time remaining: " . (defined $energy_time_remaining_hours ? sprintf("%.2f", $energy_time_remaining_hours) . " h" : "N/A")
			);

			# Send the open notice only if it wasn't already sent for this paid_kwh
			if (!defined $d->{last_notification_sent_time} || ($d->{last_paid_kwh_marker} || 0) != $est->{paid_kwh}) {
				my $notification = $UP_MESSAGE;
				$notification =~ s/\{serial\}/$d->{serial}/g;
				$notification =~ s/\{info\}/$d->{info}/g;
				$notification =~ s/\{time_remaining\}/$time_remaining_string/g;
				sms_send($d->{sms_notification}, $notification);
				log_info("Open notice sent after top-up for serial " . $d->{serial});
			}

			# Reset state to 0
			$new_state = 0;
			$update_needed = 1;

			# Update last_paid_kwh_marker
			$new_last_paid_kwh_marker = $est->{paid_kwh};
		}

		# --- Notifications ---
		my $close_warning_threshold = $d->{close_notification_time} ? $d->{close_notification_time} / 3600 : $CLOSE_WARNING_TIME;

		# Close warning: transition state from 0 to 1
		if ($d->{notification_state} == 0) {
			if ((defined $energy_time_remaining_hours && $energy_time_remaining_hours < $close_warning_threshold) || ($energy_remaining <= $d->{min_amount})) {

				# Debug log for sending close warning notification
				log_warn(
					"Serial: $d->{serial}",
					"State: 0 → 1",
					"Energy remaining: " . sprintf("%.2f", $energy_remaining) . " kWh",
					"Paid kWh: " . sprintf("%.2f", $est->{paid_kwh} || 0) . " kWh",
					"Avg energy last day: " . sprintf("%.2f", $est->{avg_energy_last_day} || 0) . " kWh",
					"Time remaining: " . (defined $energy_time_remaining_hours ? sprintf("%.2f", $energy_time_remaining_hours) . " h" : "N/A"),
					"Notification sent at: " . ($d->{last_notification_sent_time} || 'N/A')
				);

				# Send the close warning notification only if not already sent for this state
				if (!defined $d->{last_notification_sent_time} || $d->{notification_state} != 1) {
					my $notification = $CLOSE_WARNING_MESSAGE;
					$notification =~ s/\{serial\}/$d->{serial}/g;
					$notification =~ s/\{info\}/$d->{info}/g;
					$notification =~ s/\{time_remaining\}/$time_remaining_string/g;
					sms_send($d->{sms_notification}, $notification);
					log_info("Close warning sent for serial " . $d->{serial});
				}

				$new_state = 1;
				$update_needed = 1;
			}
		}

		# Close notice: transition state from 1 to 2
		elsif ($d->{notification_state} == 1) {
			if ($energy_remaining <= $CLOSE_THRESHOLD) {

				# Debug log for sending close notice
				log_warn(
					"Serial: $d->{serial}",
					"State: 1 → 2",
					"Energy remaining: " . sprintf("%.2f", $energy_remaining) . " kWh",
					"Paid kWh: " . sprintf("%.2f", $est->{paid_kwh} || 0) . " kWh",
					"Avg energy last day: " . sprintf("%.2f", $est->{avg_energy_last_day} || 0) . " kWh",
					"Time remaining: " . (defined $energy_time_remaining_hours ? sprintf("%.2f", $energy_time_remaining_hours) . " h" : "N/A"),
					"Notification sent at: " . ($d->{last_notification_sent_time} || 'N/A')
				);

				# Send the close notice only if not already sent for this state
				if (!defined $d->{last_notification_sent_time} || $d->{notification_state} != 2) {
					my $notification = $DOWN_MESSAGE;
					$notification =~ s/\{serial\}/$d->{serial}/g;
					$notification =~ s/\{info\}/$d->{info}/g;
					$notification =~ s/\{time_remaining\}/$time_remaining_string/g;
					sms_send($d->{sms_notification}, $notification);
					log_info("Close notice sent for serial " . $d->{serial});
				}

				$new_state = 2;
				$update_needed = 1;
			}
		}

		# Open notice: transition state from 2 to 0
		elsif ($d->{notification_state} == 2) {
			if (defined $energy_time_remaining_hours && $energy_remaining > $CLOSE_THRESHOLD) {

				# Debug log for sending open notice
				log_warn(
					"Serial: $d->{serial}",
					"State: 2 → 0",
					"Energy remaining: " . sprintf("%.2f", $energy_remaining) . " kWh",
					"Paid kWh: " . sprintf("%.2f", $est->{paid_kwh} || 0) . " kWh",
					"Avg energy last day: " . sprintf("%.2f", $est->{avg_energy_last_day} || 0) . " kWh",
					"Time remaining: " . (defined $energy_time_remaining_hours ? sprintf("%.2f", $energy_time_remaining_hours) . " h" : "N/A"),
					"Notification sent at: " . ($d->{last_notification_sent_time} || 'N/A')
				);

				# Send the open notice only if not already sent for this state
				if (!defined $d->{last_notification_sent_time} || $d->{notification_state} != 0) {
					my $notification = $UP_MESSAGE;
					$notification =~ s/\{serial\}/$d->{serial}/g;
					$notification =~ s/\{info\}/$d->{info}/g;
					$notification =~ s/\{time_remaining\}/$time_remaining_string/g;
					sms_send($d->{sms_notification}, $notification);
					log_info("Open notice sent for serial " . $d->{serial});
				}

				$new_state = 0;
				$update_needed = 1;
			}
		}

		# --- Always update last_paid_kwh_marker if paid kWh increased ---
		if (!defined $new_last_paid_kwh_marker || ($est->{paid_kwh} || 0) > ($d->{last_paid_kwh_marker} || 0)) {
			$new_last_paid_kwh_marker = $est->{paid_kwh} || 0;
			$update_needed = 1;
		}

		# --- Perform combined DB upsert in meters_state if needed ---
		if ($update_needed) {
			my $now = time();
			$dbh->do(qq[
				INSERT INTO meters_state
					(serial, close_notification_time, notification_state, last_paid_kwh_marker, last_notification_sent_time)
				VALUES
					($quoted_serial, $d->{close_notification_time}, $new_state, $new_last_paid_kwh_marker, $now)
				ON DUPLICATE KEY UPDATE
					notification_state = VALUES(notification_state),
					last_paid_kwh_marker = VALUES(last_paid_kwh_marker),
					last_notification_sent_time = VALUES(last_notification_sent_time)
			]) or log_warn("[ERROR] DB upsert failed for serial " . $d->{serial});
		}
	}

	sleep 1;
}

# --- helper to send SMS ---
sub sms_send {
	my ($sms_notification, $message) = @_;
	return unless $sms_notification;

	my @numbers = ($sms_notification =~ /(\d+)(?:,\s?)*/g);
	foreach my $num (@numbers) {
		log_info("Sending SMS to 45$num: $message", { -custom_tag => 'SMS' });
		my $ok = send_notification($num, $message);
		unless ($ok) {
			log_warn("Failed to send SMS to 45$num", { -custom_tag => 'SMS' });
		}
	}
}
