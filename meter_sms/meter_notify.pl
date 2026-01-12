#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
use Data::Dumper;
use DBI;

use Nabovarme::Db;
use Nabovarme::Utils;
use Nabovarme::EnergyEstimator;

$| = 1;
STDOUT->autoflush(1);
STDERR->autoflush(1);

log_warn("Starting SMS notification script...");

# --- Environment messages ---
my $OPEN_MESSAGE           = $ENV{NOTIFICATION_OPEN_MESSAGE}           || 'Open notice: {info} open. {time_remaining} remaining. ({serial})';
my $CLOSE_MESSAGE          = $ENV{NOTIFICATION_CLOSE_MESSAGE}          || 'Close notice: {info} closed. ({serial})';
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

my $shutdown_requested = 0;

# Catch TERM and INT signals (Docker bruger TERM)
$SIG{TERM} = sub {
	log_info("SIGTERM received, will shutdown after current loop...");
	$shutdown_requested = 1;
};

$SIG{INT} = sub {
	log_info("SIGINT received, will shutdown after current loop...");
	$shutdown_requested = 1;
};

while (1) {

	# --- Fetch meters ---
	$sth = $dbh->prepare(qq[
		SELECT 
			m.serial, m.info, m.min_amount, m.valve_status, m.valve_installed,
			m.sw_version, m.email_notification, m.sms_notification,
			ms.kwh_remaining, ms.time_remaining_hours,
			ms.notification_state, ms.paid_kwh, ms.last_paid_kwh_marker,
			ms.last_notification_sent_time, ms.close_warning_threshold
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
		my $time_remaining_string = $d->{time_remaining_hours_string} // '∞';

		my $state             = $d->{notification_state} // 0;
		my $last_paid_marker  = $d->{last_paid_kwh_marker} // 0;
		my $last_sent_time    = $d->{last_notification_sent_time} // 0;
		my $notification_sent = 0;

		# --- Close warning threshold in hours ---
		my $close_warning_threshold = defined $d->{close_warning_threshold}
			? $d->{close_warning_threshold}/3600
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
				sms_send($serial, 'OPEN');
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

			# --- skip state machine since we've already handled notifications ---
			next;
		}

		# ============================================================
		# --- STATE MACHINE ---
		# ============================================================
		if (!$notification_sent) {
			if ($state == 0) {
				if ($energy_remaining <= $CLOSE_THRESHOLD) {
					$state = 2;
					sms_send($serial, 'CLOSE');
					log_info("Close notice sent (state 0 → 2) for serial $serial");
					$last_sent_time = time();
				}
				elsif (defined $time_remaining_hours && $time_remaining_hours < $close_warning_threshold) {
					$state = 1;
					sms_send($serial, 'CLOSE_WARNING');
					log_info("Close warning sent (state 0 → 1) for serial $serial");
					$last_sent_time = time();
				}
			}
			elsif ($state == 1) {
				if ($energy_remaining <= $CLOSE_THRESHOLD) {
					$state = 2;
					sms_send($serial, 'CLOSE');
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
				(serial, close_warning_threshold, notification_state, last_notification_sent_time, last_paid_kwh_marker)
			VALUES
				($quoted_serial, ?, ?, ?, ?)
			ON DUPLICATE KEY UPDATE
				notification_state = VALUES(notification_state),
				last_notification_sent_time = VALUES(last_notification_sent_time),
				last_paid_kwh_marker = VALUES(last_paid_kwh_marker)
		], undef,
			$d->{close_warning_threshold} // $CLOSE_WARNING_TIME*3600,
			$state,
			$last_sent_time,
			$d->{paid_kwh}
		);
	}

	last if $shutdown_requested;
	sleep 1;
}

# --- helper to send SMS ---
sub sms_send {
	my ($serial, $type) = @_;
	return unless $serial;

	# --- Lookup the meter from DB ---
	my $sth = $dbh->prepare(qq[
		SELECT *
		FROM meters
		WHERE serial = ?
		  AND (sms_notification IS NOT NULL AND sms_notification != '')
		LIMIT 1
	]) or log_die("Failed to prepare statement for meter lookup: $DBI::errstr");
	$sth->execute($serial) or log_die("Failed to execute statement for meter lookup: $DBI::errstr");

	my $d = $sth->fetchrow_hashref;
	unless ($d) {
		log_warn("No SMS-enabled meter found for serial $serial");
		return;
	}

	return unless $d->{sms_notification};

	# --- Choose message template based on type ---
	my %messages = (
		OPEN          => $OPEN_MESSAGE,
		CLOSE         => $CLOSE_MESSAGE,
		CLOSE_WARNING => $CLOSE_WARNING_MESSAGE,
	);
	my $message_template = $messages{$type};
	return unless $message_template;

	# --- Force recalc of time_remaining ---
	my $est = Nabovarme::EnergyEstimator::estimate_remaining_energy($dbh, $serial, 1);
	my $time_remaining_string = $est->{time_remaining_hours_string} // '∞';
	my $info                  = $d->{info} // '';

	# --- Substitute placeholders ---
	my $message = $message_template;
	$message =~ s/\{serial\}/$serial/g;
	$message =~ s/\{info\}/$info/g;
	$message =~ s/\{time_remaining\}/$time_remaining_string/g;

	# --- Send SMS to all numbers ---
	my @numbers = ($d->{sms_notification} =~ /(\d+)(?:,\s?)*/g);
	foreach my $num (@numbers) {
		log_info("Sending SMS to 45$num: $message", { -custom_tag => 'SMS' });
		my $ok = send_notification($num, $message);
		unless ($ok) {
			log_warn("Failed to send SMS to 45$num", { -custom_tag => 'SMS' });
		}
	}
}
