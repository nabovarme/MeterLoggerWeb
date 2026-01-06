#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
use Data::Dumper;
use DBI;

use Nabovarme::Db;
use Nabovarme::Utils;

$| = 1;
STDOUT->autoflush(1);
STDERR->autoflush(1);

log_warn("Starting SMS notification script...");

# --- Environment messages ---
my $UP_MESSAGE             = $ENV{NOTIFICATION_UP_MESSAGE}             || 'Open notice: {info} open. {time_remaining} remaining. ({serial})';
my $DOWN_MESSAGE           = $ENV{NOTIFICATION_DOWN_MESSAGE}           || 'Close notice: {info} closed. ({serial})';
my $CLOSE_WARNING_MESSAGE  = $ENV{NOTIFICATION_CLOSE_WARNING_MESSAGE}  || 'Close warning: {info}. {time_remaining} remaining. ({serial})';
my $CLOSE_WARNING_TIME     = $ENV{NOTIFICATION_CLOSE_WARNING_TIME}     || 3 * 24; # 3 days in hours

my $HYST = 0.5;
my $CLOSE_THRESHOLD = 1;

my ($dbh, $sth, $d);

# --- DB connection ---
if ($dbh = Nabovarme::Db->my_connect) {
	$dbh->{'mysql_auto_reconnect'} = 1;
	log_info("Connected to DB");
} else {
	log_die("Can't connect to DB: $!");
}

while (1) {

	# --- Fetch meters ---
	$sth = $dbh->prepare(qq[
		SELECT 
			m.serial, m.info, m.min_amount, m.valve_status, m.valve_installed,
			m.sw_version, m.email_notification, m.sms_notification,
			ms.kwh_remaining, ms.time_remaining_hours,
			ms.notification_state, ms.paid_kwh, ms.last_paid_kwh_marker,
			ms.last_notification_sent_time, ms.close_notification_time
		FROM meters m
		LEFT JOIN meters_state ms ON ms.serial = m.serial
		WHERE m.enabled = 1
			AND m.valve_installed = 1
			AND m.type = 'heat'
			AND (m.email_notification OR m.sms_notification)
	]);
	$sth->execute or log_warn($DBI::errstr);

	while ($d = $sth->fetchrow_hashref) {
		my $serial = $d->{serial};
		my $info   = $d->{info} // '';

		my $energy_remaining      = $d->{kwh_remaining} // 0;
		my $time_remaining_hours  = $d->{time_remaining_hours};
		my $time_remaining_string = defined $time_remaining_hours ? sprintf("%.2f h", $time_remaining_hours) : '∞';

		my $state             = $d->{notification_state} // 0;
		my $last_paid_marker  = $d->{last_paid_kwh_marker} // 0;
		my $last_sent_time    = $d->{last_notification_sent_time} // 0;
		my $notification_sent = 0;

		# --- Close warning threshold in hours ---
		my $close_warning_threshold = defined $d->{close_notification_time}
			? $d->{close_notification_time}/3600
			: $CLOSE_WARNING_TIME;

#		log_debug(
#			"Serial: $serial",
#			"State: $state",
#			"Energy remaining: $energy_remaining",
#			"Time remaining: $time_remaining_string",
#			"Paid kWh: " . ($d->{paid_kwh} // 0),
#			"Last paid marker: $last_paid_marker",
#			"Last notification: " . ($last_sent_time ? scalar localtime($last_sent_time) : 'N/A')
#		);

		# ============================================================
		# --- TOP-UP CHECK ---
		# ============================================================
		if (defined $d->{paid_kwh} && $d->{paid_kwh} > $last_paid_marker + $HYST) {

			# Send Open notice SMS only if not already sent for this paid_kwh
			if (!defined $last_sent_time || $last_paid_marker != $d->{paid_kwh}) {
				my $msg = $UP_MESSAGE;
				$msg =~ s/\{serial\}/$serial/g;
				$msg =~ s/\{info\}/$info/g;
				$msg =~ s/\{time_remaining\}/$time_remaining_string/g;
				sms_send($d->{sms_notification}, $msg);
				log_info("Top-up Open notice sent for serial $serial");

				$last_sent_time = time();
				$notification_sent = 1;
			}

			# Update last_paid_kwh_marker in DB
			$dbh->do(qq[
				UPDATE meters_state
				SET last_paid_kwh_marker = ?
				WHERE serial = ?
			], undef, $d->{paid_kwh}, $serial);

			# Reset state to 0 after top-up
			$state = 0;

			# --- Immediately check low energy after top-up ---
			if ($energy_remaining <= $CLOSE_THRESHOLD && !$notification_sent) {
				$state = 1;
				my $warn_msg = $CLOSE_WARNING_MESSAGE;
				$warn_msg =~ s/\{serial\}/$serial/g;
				$warn_msg =~ s/\{info\}/$info/g;
				$warn_msg =~ s/\{time_remaining\}/$time_remaining_string/g;
				sms_send($d->{sms_notification}, $warn_msg);
				log_info("Close warning sent immediately after top-up for serial $serial");
				$last_sent_time = time();
				$notification_sent = 1;
			}
		}

		# ============================================================
		# --- STATE MACHINE ---
		# ============================================================
		if (!$notification_sent) {
			if ($state == 0) {
				if ($energy_remaining <= $CLOSE_THRESHOLD) {
					$state = 2;
					my $msg = $DOWN_MESSAGE;
					$msg =~ s/\{serial\}/$serial/g;
					$msg =~ s/\{info\}/$info/g;
					$msg =~ s/\{time_remaining\}/$time_remaining_string/g;
					sms_send($d->{sms_notification}, $msg);
					log_info("Close notice sent (state 0 → 2) for serial $serial");
					$last_sent_time = time();
				}
				elsif (defined $time_remaining_hours && $time_remaining_hours < $close_warning_threshold) {
					$state = 1;
					my $msg = $CLOSE_WARNING_MESSAGE;
					$msg =~ s/\{serial\}/$serial/g;
					$msg =~ s/\{info\}/$info/g;
					$msg =~ s/\{time_remaining\}/$time_remaining_string/g;
					sms_send($d->{sms_notification}, $msg);
					log_info("Close warning sent (state 0 → 1) for serial $serial");
					$last_sent_time = time();
				}
			}
			elsif ($state == 1) {
				if ($energy_remaining <= $CLOSE_THRESHOLD) {
					$state = 2;
					my $msg = $DOWN_MESSAGE;
					$msg =~ s/\{serial\}/$serial/g;
					$msg =~ s/\{info\}/$info/g;
					$msg =~ s/\{time_remaining\}/$time_remaining_string/g;
					sms_send($d->{sms_notification}, $msg);
					log_info("Close notice sent (state 1 → 2) for serial $serial");
					$last_sent_time = time();
				}
				elsif (defined $time_remaining_hours && $time_remaining_hours >= $close_warning_threshold) {
					$state = 0;
					log_info("State reverted to 0 (state 1 → 0) for serial $serial");
				}
			}
			elsif ($state == 2) {
				if ($energy_remaining > $CLOSE_THRESHOLD + $HYST) {
					$state = 0;
					log_info("State reverted to 0 (state 2 → 0) for serial $serial");
				}
			}
		}

		# ============================================================
		# --- Update meters_state in DB ---
		# ============================================================
		my $quoted_serial = $dbh->quote($serial);
		$dbh->do(qq[
			INSERT INTO meters_state
				(serial, close_notification_time, notification_state, last_notification_sent_time, last_paid_kwh_marker)
			VALUES
				($quoted_serial, ?, ?, ?, ?)
			ON DUPLICATE KEY UPDATE
				notification_state = VALUES(notification_state),
				last_notification_sent_time = VALUES(last_notification_sent_time),
				last_paid_kwh_marker = VALUES(last_paid_kwh_marker)
		], undef,
			$d->{close_notification_time} // $CLOSE_WARNING_TIME*3600,
			$state,
			$last_sent_time,
			$d->{paid_kwh}
		);
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
