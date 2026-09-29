package Nabovarme::APINotificationSettings;

use strict;
use warnings;
use utf8;
use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::Const -compile => qw(OK HTTP_FORBIDDEN HTTP_SERVICE_UNAVAILABLE HTTP_BAD_REQUEST HTTP_INTERNAL_SERVER_ERROR);
use JSON qw(encode_json decode_json);

use Nabovarme::Utils;
use Nabovarme::Db;
use Nabovarme::Utils;
use Nabovarme::Admin;
use Nabovarme::Number::Phone;

sub handler {
	my $r = shift;

	my $dbh = Nabovarme::Db->my_connect;
	unless ($dbh) {
		log_error("[APINotificationSettings] Could not connect to database");
		$r->err_headers_out->set('Retry-After' => '60');
		return Apache2::Const::HTTP_SERVICE_UNAVAILABLE;
	}

	$r->content_type("application/json; charset=utf-8");
	$r->headers_out->set('Cache-Control' => 'no-cache, no-store, must-revalidate');

	# Authenticate session strictly via cookie
	my $admin = Nabovarme::Admin->new;
	my $raw_phone = eval { $admin->phone_by_cookie($r) };
	if ($@) {
		log_error("[APINotificationSettings] Session lookup error: $@");
	}

	unless ($raw_phone) {
		log_debug("[APINotificationSettings] Unauthorized access attempt - no valid session cookie");
		$r->status(Apache2::Const::HTTP_FORBIDDEN);
		$r->print(encode_json({ success => 0, error => "Forbidden: User must be logged in" }));
		return Apache2::Const::OK;
	}

	# Compact phone number (+45XXXXXXXX)
	my $phone_obj = Nabovarme::Number::Phone->new($raw_phone);
	my $phone = ($phone_obj && $phone_obj->is_valid) ? $phone_obj->compact : $raw_phone;

	my $method = $r->method;

	# --- GET REQUEST (Fetch Current Settings) ---
	if ($method eq 'GET') {
		my $alarm_enabled = 1;
		my $channels = { sms_enabled => 1, push_enabled => 0 };

		eval {
			# 1. Fetch user master enable flag
			my $user_sth = $dbh->prepare(qq[
				SELECT alarm_enabled
				FROM users
				WHERE phone = ?
				LIMIT 1
			]);
			$user_sth->execute($phone);
			my ($val) = $user_sth->fetchrow_array;
			$alarm_enabled = defined $val ? int($val) : 1;

			# 2. Determine aggregated channel statuses across user's alarms
			my $alarm_sth = $dbh->prepare(qq[
				SELECT 
					COALESCE(MAX(sms_enabled), 1) AS sms_enabled,
					COALESCE(MAX(push_enabled), 0) AS push_enabled
				FROM alarms
				WHERE sms_notification LIKE ?
			]);
			$alarm_sth->execute('%' . $phone . '%');
			if (my $row = $alarm_sth->fetchrow_hashref) {
				$channels = $row;
			}
		};

		if ($@) {
			log_error("[APINotificationSettings] SQL GET error for phone '$phone': $@");
			$r->status(Apache2::Const::HTTP_INTERNAL_SERVER_ERROR);
			$r->print(encode_json({ success => 0, error => "Database query failed" }));
			return Apache2::Const::OK;
		}

		log_debug(sprintf("[APINotificationSettings] Loaded settings for %s -> alarm_enabled: %d, sms: %d, push: %d",
			$phone, $alarm_enabled, $channels->{sms_enabled}, $channels->{push_enabled}));

		$r->print(encode_json({
			success       => 1,
			alarm_enabled => int($alarm_enabled),
			sms_enabled   => int($channels->{sms_enabled} // 1),
			push_enabled  => int($channels->{push_enabled} // 0),
		}));
		return Apache2::Const::OK;
	}

	# --- POST/PUT REQUEST (Update Global & Bulk Update Alarms) ---
	if ($method eq 'POST' || $method eq 'PUT') {
		my $body_data = '';
		my $content_length = $r->headers_in->{'Content-Length'} || 0;
		if ($content_length > 0) {
			$r->read($body_data, $content_length);
		}

		my $payload = eval { decode_json($body_data) } || {};

		my $global_enabled = $payload->{alarm_enabled} ? 1 : 0;
		my $sms_enabled    = $payload->{sms_enabled}   ? 1 : 0;
		my $push_enabled   = $payload->{push_enabled}  ? 1 : 0;

		my $updated_alarms = 0;
		my $updated_auto   = 0;

		eval {
			# 1. Update master toggle in users table
			my $update_user_sth = $dbh->prepare(qq[
				UPDATE users
				SET alarm_enabled = ?
				WHERE phone = ?
			]);
			$update_user_sth->execute($global_enabled, $phone);

			# 2. Bulk-update sms_enabled and push_enabled across all individual alarms for this phone
			my $update_alarms_sth = $dbh->prepare(qq[
				UPDATE alarms
				SET sms_enabled = ?, push_enabled = ?
				WHERE sms_notification LIKE ?
			]);
			$updated_alarms = $update_alarms_sth->execute($sms_enabled, $push_enabled, '%' . $phone . '%') || 0;

			# 3. Bulk-update alarms_auto templates matching this phone
			my $update_auto_sth = $dbh->prepare(qq[
				UPDATE alarms_auto
				SET sms_enabled = ?, push_enabled = ?
				WHERE sms_notification LIKE ?
			]);
			$updated_auto = $update_auto_sth->execute($sms_enabled, $push_enabled, '%' . $phone . '%') || 0;
		};

		if ($@) {
			log_error("[APINotificationSettings] SQL UPDATE error for phone '$phone': $@");
			$r->status(Apache2::Const::HTTP_INTERNAL_SERVER_ERROR);
			$r->print(encode_json({ success => 0, error => "Failed to update notification settings" }));
			return Apache2::Const::OK;
		}

		log_warn(sprintf("[APINotificationSettings] Updated settings for %s -> master: %d, sms: %d, push: %d (Updated %d alarms, %d auto_alarms)",
			$phone, $global_enabled, $sms_enabled, $push_enabled, $updated_alarms, $updated_auto));

		$r->print(encode_json({ success => 1, message => "Notification settings updated globally" }));
		return Apache2::Const::OK;
	}

	$r->status(Apache2::Const::HTTP_BAD_REQUEST);
	$r->print(encode_json({ success => 0, error => "Unsupported HTTP method" }));
	return Apache2::Const::OK;
}

1;
