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
my $CLOSE_WARNING_MESSAGE  = $ENV{CLOSE_WARNING_MESSAGE}  || 'Close warning: {info}. {time_remaining} remaining. ({serial})';
my $CLOSE_WARNING_TIME     = $ENV{CLOSE_WARNING_TIME}     || 3 * 24; # 3 days in hours

my $HYST = 0.5;
my $CLOSE_THRESHOLD = 1;

my ($dbh, $sth, $d);

# connect to db
if ($dbh = Nabovarme::Db->my_connect) {
	$dbh->{'mysql_auto_reconnect'} = 1;
	log_info("Connected to DB");
} else {
	log_die("Can't connect to DB: $!");
}

while (1) {
	# --- Fetch all enabled heat meters with valve installed ---
	$sth = $dbh->prepare(qq[
		SELECT 
			m.serial, m.info, m.min_amount, m.valve_status, m.valve_installed,
			m.sw_version, m.email_notification, m.sms_notification,
			ms.kwh_remaining, ms.time_remaining_hours,
			ms.notification_state, ms.paid_kwh, ms.last_paid_kwh_marker,
			ms.last_close_warning_kwh_marker, ms.last_notification_sent_time,
			ms.close_notification_time
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

		# --- Use meters_state directly ---
		my $energy_remaining      = $d->{kwh_remaining} // 0;
		my $time_remaining_hours  = $d->{time_remaining_hours};
		my $time_remaining_string = defined $time_remaining_hours ? sprintf("%.2f h", $time_remaining_hours) : '∞';

		my $state            = $d->{notification_state} // 0;
		my $last_paid_marker  = $d->{last_paid_kwh_marker} // 0;
		my $notification_sent = 0;

		# --- DEBUG LOG ---
		log_debug(
			"Serial: $serial",
			"State: $state",
			"Energy remaining: $energy_remaining",
			"Time remaining: $time_remaining_string",
			"Paid kWh: " . ($d->{paid_kwh} // 0),
			"Last paid marker: $last_paid_marker"
		);

		# ============================================================
		# --- TOP-UP CHECK (independent of state machine) ---
		# ============================================================
		if (defined $d->{paid_kwh} && $d->{paid_kwh} > $last_paid_marker + $HYST) {

			# Send Open notice SMS (Top-up)
			my $msg = $UP_MESSAGE;
			$msg =~ s/\{serial\}/$serial/g;
			$msg =~ s/\{info\}/$info/g;
			$msg =~ s/\{time_remaining\}/$time_remaining_string/g;
			sms_send($d->{sms_notification}, $msg);
			log_info("Top-up Open notice sent for serial $serial");

			# Update last_paid_kwh_marker
			$dbh->do(qq[
				UPDATE meters_state
				SET last_paid_kwh_marker = ?
				WHERE serial = ?
			], undef, $d->{paid_kwh}, $serial);

			# Reset state to 0 initially
			$state = 0;
			$notification_sent = 1;

			# --- Immediately check if energy_remaining <= CLOSE_THRESHOLD ---
			if ($energy_remaining <= $CLOSE_THRESHOLD) {
				# Send Close warning immediately after top-up
				$state = 1;
				my $warning_msg = $CLOSE_WARNING_MESSAGE;
				$warning_msg =~ s/\{serial\}/$serial/g;
				$warning_msg =~ s/\{info\}/$info/g;
				$warning_msg =~ s/\{time_remaining\}/$time_remaining_string/g;
				sms_send($d->{sms_notification}, $warning_msg);
				log_info("Close warning sent immediately after top-up for serial $serial (energy <= CLOSE_THRESHOLD)");
			}
		}

		# ============================================================
		# --- STATE MACHINE ---
		# ============================================================
		my $close_warning_threshold = $d->{close_notification_time} ? $d->{close_notification_time}/3600 : $CLOSE_WARNING_TIME;

		# State 0 – Ingen open notice (kun top-up sender SMS)
		if ($state == 0 && !$notification_sent) {
			if ($energy_remaining <= $CLOSE_THRESHOLD) {
				# → State 2 Close Notice
				$state = 2;
				my $msg = $DOWN_MESSAGE;
				$msg =~ s/\{serial\}/$serial/g;
				$msg =~ s/\{info\}/$info/g;
				$msg =~ s/\{time_remaining\}/$time_remaining_string/g;
				sms_send($d->{sms_notification}, $msg);
				log_info("Close notice sent for serial $serial (state 0 → 2)");
			}
			elsif (defined $time_remaining_hours && $time_remaining_hours < $close_warning_threshold) {
				# → State 1 Close Warning
				$state = 1;
				my $msg = $CLOSE_WARNING_MESSAGE;
				$msg =~ s/\{serial\}/$serial/g;
				$msg =~ s/\{info\}/$info/g;
				$msg =~ s/\{time_remaining\}/$time_remaining_string/g;
				sms_send($d->{sms_notification}, $msg);
				log_info("Close warning sent for serial $serial (state 0 → 1)");
			}
		}

		# State 1 – Close Warning
		elsif ($state == 1 && !$notification_sent) {
			if ($energy_remaining <= $CLOSE_THRESHOLD) {
				# → State 2 Close Notice
				$state = 2;
				my $msg = $DOWN_MESSAGE;
				$msg =~ s/\{serial\}/$serial/g;
				$msg =~ s/\{info\}/$info/g;
				$msg =~ s/\{time_remaining\}/$time_remaining_string/g;
				sms_send($d->{sms_notification}, $msg);
				log_info("Close notice sent for serial $serial (state 1 → 2)");
			}
			elsif (defined $time_remaining_hours && $time_remaining_hours >= $close_warning_threshold) {
				# → State 0 Open notice (kun top-up SMS)
				$state = 0;
				log_info("State reverted to 0 for serial $serial (state 1 → 0)");
			}
		}

		# State 2 – Close Notice
		elsif ($state == 2 && !$notification_sent) {
			if ($energy_remaining > $CLOSE_THRESHOLD + $HYST) {
				# → State 0 Open notice (kun top-up SMS)
				$state = 0;
				log_info("State reverted to 0 for serial $serial (state 2 → 0)");
			}
		}

		# ============================================================
		# --- Update meters_state in DB ---
		# ============================================================
		my $quoted_serial = $dbh->quote($serial);
		my $now = time();
		$dbh->do(qq[
			INSERT INTO meters_state
				(serial, close_notification_time, notification_state, last_notification_sent_time, last_paid_kwh_marker)
			VALUES
				($quoted_serial, ?, ?, ?, ?)
			ON DUPLICATE KEY UPDATE
				notification_state = VALUES(notification_state),
				last_notification_sent_time = VALUES(last_notification_sent_time),
				last_paid_kwh_marker = VALUES(last_paid_kwh_marker)
		], undef, $d->{close_notification_time} // $CLOSE_WARNING_TIME*3600, $state, $now, $d->{paid_kwh});
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
