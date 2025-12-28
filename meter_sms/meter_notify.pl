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
		SELECT `serial`, info, min_amount, valve_status, valve_installed,
			   sw_version, email_notification, sms_notification,
			   close_notification_time, notification_state, last_paid_kwh_marker
		FROM meters
		WHERE enabled
		  AND type = 'heat'
		  AND (email_notification OR sms_notification)
	]);
	$sth->execute or log_warn($DBI::errstr);

	while ($d = $sth->fetchrow_hashref) {

		my $quoted_serial = $dbh->quote($d->{serial});

		# Get the latest energy estimates
		my $est = Nabovarme::Utils::estimate_remaining_energy($dbh, $d->{serial});

		$energy_remaining            = ($est->{kwh_remaining} || 0) - ($d->{min_amount} || 0);
		$energy_time_remaining_hours = $est->{time_remaining_hours};
		my $time_remaining_string    = $est->{time_remaining_hours_string};

		# Calculate paid kWh and average energy used during the last day
		my $paid_kwh = sprintf("%.2f", $est->{paid_kwh} || 0);
		my $avg_energy_last_day = sprintf("%.2f", $est->{avg_energy_last_day} || 0);
		my $energy_remaining_fmt = sprintf("%.2f", $energy_remaining);
		my $time_remaining_fmt = defined $energy_time_remaining_hours ? sprintf("%.2f", $energy_time_remaining_hours) : "N/A";

		# --- Determine if last_paid_kwh_marker or state needs updating ---
		my $new_state = $d->{notification_state};
		my $new_last_paid_kwh_marker = $d->{last_paid_kwh_marker};
		my $update_needed = 0;

		# --- Notifications ---
		my $close_warning_threshold = $d->{close_notification_time} ? $d->{close_notification_time} / 3600 : $CLOSE_WARNING_TIME;

		# Close warning: transition state from 0 to 1
		if ($d->{notification_state} == 0) {
			if ((defined $energy_time_remaining_hours && $energy_time_remaining_hours < $close_warning_threshold) || ($energy_remaining <= $d->{min_amount})) {

				# Debug log for sending close warning notification
				log_warn(
					"Serial: $d->{serial}",
					"State: 0 → 1",
					"Energy remaining: $energy_remaining_fmt kWh",
					"Paid kWh: $paid_kwh kWh",
					"Avg energy last day: $avg_energy_last_day kWh",
					"Time remaining: $time_remaining_fmt h",
					"Notification sent at: " . ($d->{last_paid_kwh_marker} || 'N/A')
				);

				# Send the close warning notification
				$notification = $CLOSE_WARNING_MESSAGE;
				$notification =~ s/\{serial\}/$d->{serial}/g;
				$notification =~ s/\{info\}/$d->{info}/g;
				$notification =~ s/\{time_remaining\}/$time_remaining_string/g;
				sms_send($d->{sms_notification}, $notification);
				log_info("Close warning sent for serial " . $d->{serial});

				$new_state = 1;
				$update_needed = 1;
			}
		}

		# Close notice: transition state from 1 to 2 or top-up: state 1 → 0
		elsif ($d->{notification_state} == 1) {

			# --- Open notice after top-up (always send if energy increased) ---
			if (defined $energy_remaining && $energy_remaining > ($d->{last_paid_kwh_marker} || 0)) {

				# Debug log for sending open notice after top-up
				log_warn(
					"Serial: $d->{serial}",
					"State: 1 → 0 (top-up)",
					"Energy remaining: $energy_remaining_fmt kWh",
					"Paid kWh: $paid_kwh kWh",
					"Avg energy last day: $avg_energy_last_day kWh",
					"Time remaining: $time_remaining_fmt h",
					"Notification sent at: " . ($d->{last_paid_kwh_marker} || 'N/A')
				);

				# Send the open notice
				$notification = $UP_MESSAGE;
				$notification =~ s/\{serial\}/$d->{serial}/g;
				$notification =~ s/\{info\}/$d->{info}/g;
				$notification =~ s/\{time_remaining\}/$time_remaining_string/g;
				sms_send($d->{sms_notification}, $notification);
				log_info("Open notice sent after top-up for serial " . $d->{serial});

				# Reset state and clear energy marker in the database
				$new_state = 0;
				$update_needed = 1;

			}

			# --- Close notice when energy is exhausted ---
			elsif ($energy_remaining <= 0) {

				# Debug log for sending close notice
				log_warn(
					"Serial: $d->{serial}",
					"State: 1 → 2",
					"Energy remaining: $energy_remaining_fmt kWh",
					"Paid kWh: $paid_kwh kWh",
					"Avg energy last day: $avg_energy_last_day kWh",
					"Time remaining: $time_remaining_fmt h",
					"Notification sent at: " . ($d->{last_paid_kwh_marker} || 'N/A')
				);

				# Send the close notice
				$notification = $DOWN_MESSAGE;
				$notification =~ s/\{serial\}/$d->{serial}/g;
				$notification =~ s/\{info\}/$d->{info}/g;
				$notification =~ s/\{time_remaining\}/$time_remaining_string/g;
				sms_send($d->{sms_notification}, $notification);
				log_info("Close notice sent for serial " . $d->{serial});

				# Update state and timestamp in the database
				$new_state = 2;
				$update_needed = 1;
			}
		}

		# Open notice: transition state from 2 to 0
		elsif ($d->{notification_state} == 2) {
			if (defined $energy_time_remaining_hours && $energy_remaining > 0) {

				# Debug log for sending open notice
				log_warn(
					"Serial: $d->{serial}",
					"State: 2 → 0",
					"Energy remaining: $energy_remaining_fmt kWh",
					"Paid kWh: $paid_kwh kWh",
					"Avg energy last day: $avg_energy_last_day kWh",
					"Time remaining: $time_remaining_fmt h",
					"Notification sent at: " . ($d->{last_paid_kwh_marker} || 'N/A')
				);

				# Send the open notice
				$notification = $UP_MESSAGE;
				$notification =~ s/\{serial\}/$d->{serial}/g;
				$notification =~ s/\{info\}/$d->{info}/g;
				$notification =~ s/\{time_remaining\}/$time_remaining_string/g;
				sms_send($d->{sms_notification}, $notification);
				log_info("Open notice sent for serial " . $d->{serial});

				# Update state and timestamp in the database
				$new_state = 0;
				$update_needed = 1;
			}
		}
		# --- Always update last_paid_kwh_marker if energy increased ---
		if (!defined $new_last_paid_kwh_marker || ($est->{paid_kwh} || 0) > ($d->{paid_kwh} || 0)) {
			$new_last_paid_kwh_marker = $est->{paid_kwh} || 0;
			$update_needed = 1;
		}
		
		# --- Perform combined DB update if needed ---
		if ($update_needed) {
			$dbh->do(qq[
				UPDATE meters
				SET notification_state = $new_state,
					last_paid_kwh_marker = $new_last_paid_kwh_marker
				WHERE serial = $quoted_serial
			]) or log_warn("[ERROR] DB update failed for serial " . $d->{serial});
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
