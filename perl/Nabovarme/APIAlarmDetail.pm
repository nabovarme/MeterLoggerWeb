package Nabovarme::APIAlarmDetail;

use strict;
use warnings;
use utf8;
use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::Const -compile => qw(OK HTTP_BAD_REQUEST HTTP_FORBIDDEN HTTP_NOT_FOUND HTTP_SERVICE_UNAVAILABLE HTTP_INTERNAL_SERVER_ERROR);
use JSON qw(encode_json decode_json);

use Nabovarme::Utils qw(log_debug log_info log_warn);
use Nabovarme::Db;
use Nabovarme::Admin;

sub handler {
	my $r = shift;

	my $dbh = Nabovarme::Db->my_connect;
	unless ($dbh) {
		log_warn("[APIAlarmDetail] Could not connect to database");
		$r->err_headers_out->set('Retry-After' => '60');
		return Apache2::Const::HTTP_SERVICE_UNAVAILABLE;
	}

	$r->content_type("application/json; charset=utf-8");
	$r->headers_out->set('Cache-Control' => 'no-cache, no-store, must-revalidate');

	my $admin = Nabovarme::Admin->new;
	my $method = $r->method;

	# Parse URL query string for ID parameter
	my %args = map { split '=', $_, 2 } split '&', ($r->args // '');
	my $id = $args{id};

	unless ($id && $id =~ /^\d+$/) {
		log_debug("[APIAlarmDetail] Invalid or missing alarm ID param in request");
		$r->status(Apache2::Const::HTTP_BAD_REQUEST);
		$r->print(encode_json({ success => 0, error => "Missing or invalid alarm 'id' parameter" }));
		return Apache2::Const::OK;
	}

	# Fetch existing alarm safely with exception handling
	my $alarm;
	eval {
		my $sth = $dbh->prepare(qq[
			SELECT alarms.*, meters.info 
			FROM alarms 
			LEFT JOIN meters ON alarms.serial = meters.serial 
			WHERE alarms.id = ?
		]);
		$sth->execute($id);
		$alarm = $sth->fetchrow_hashref;
	};

	if ($@) {
		my $err = $@;
		log_warn("[APIAlarmDetail] SQL error fetching alarm ID '$id': " . ($err || ''));
		$r->status(Apache2::Const::HTTP_INTERNAL_SERVER_ERROR);
		$r->print(encode_json({ success => 0, error => "Database query failed" }));
		return Apache2::Const::OK;
	}

	unless ($alarm) {
		log_debug("[APIAlarmDetail] Alarm ID '$id' not found");
		$r->status(Apache2::Const::HTTP_NOT_FOUND);
		$r->print(encode_json({ success => 0, error => "Alarm not found" }));
		return Apache2::Const::OK;
	}

	my $is_admin = eval {
		$admin->cookie_is_admin_for_serial($r, $alarm->{serial})
	};

	if ($@) {
		my $err = $@;
		log_warn("[APIAlarmDetail] Permission check error for serial '$alarm->{serial}': " . ($err || ''));
	}

	# --- GET REQUEST (Fetch details) ---
	if ($method eq 'GET') {
		log_debug(sprintf("[APIAlarmDetail] GET alarm ID %s (serial: %s, is_admin: %d)", $id, $alarm->{serial} // '', $is_admin ? 1 : 0));
		$alarm->{is_admin} = $is_admin ? 1 : 0;
		$r->print(encode_json({ success => 1, alarm => $alarm }));
		return Apache2::Const::OK;
	}

	# --- POST/PUT REQUEST (Update details) ---
	if ($method eq 'POST' || $method eq 'PUT') {
		unless ($is_admin) {
			log_debug(sprintf("[APIAlarmDetail] Unauthorized update attempt for alarm ID %s (serial: %s)", $id, $alarm->{serial} // ''));
			$r->status(Apache2::Const::HTTP_FORBIDDEN);
			$r->print(encode_json({ success => 0, error => "Forbidden: Admin permission required" }));
			return Apache2::Const::OK;
		}

		my $body_data = '';
		my $content_length = $r->headers_in->{'Content-Length'} || 0;
		if ($content_length > 0) {
			$r->read($body_data, $content_length);
		}

		my $fdat = eval { decode_json($body_data) } || {};

		eval {
			update_alarm_and_set_ignore_if_changed($dbh, $id, $alarm, $fdat);
		};

		if ($@) {
			my $err = $@;
			log_warn("[APIAlarmDetail] SQL update failed for alarm ID '$id': " . ($err || ''));
			$r->status(Apache2::Const::HTTP_INTERNAL_SERVER_ERROR);
			$r->print(encode_json({ success => 0, error => "Failed to update alarm" }));
			return Apache2::Const::OK;
		}

		log_warn(sprintf("[APIAlarmDetail] Alarm ID %s updated successfully for serial %s", $id, $alarm->{serial} // ''));

		$r->print(encode_json({ success => 1, message => "Alarm updated successfully" }));
		return Apache2::Const::OK;
	}

	$r->status(Apache2::Const::HTTP_BAD_REQUEST);
	$r->print(encode_json({ success => 0, error => "Unsupported HTTP method" }));
	return Apache2::Const::OK;
}

sub hhmm_to_sec {
	my ($hhmm) = @_;
	return undef unless defined $hhmm;
	$hhmm =~ s/^\s+|\s+$//g;
	return undef if $hhmm eq '';
	return undef unless $hhmm =~ /^(\d{1,2}):(\d{2})$/;

	my ($h, $m) = ($1, $2);
	return undef if $h > 23 || $m > 59;

	return ($h * 3600) + ($m * 60);
}

sub update_alarm_and_set_ignore_if_changed {
	my ($dbh, $id, $old, $fdat) = @_;

	my $old_ignore = $old->{ignore_auto_update} ? 1 : 0;
	my $new_ignore = ($old->{auto_id} && $fdat->{ignore_auto_update}) ? 1 : 0;

	$fdat->{sms_notification} ||= '';
	$fdat->{sms_enabled}        = $fdat->{sms_enabled} ? 1 : 0;
	$fdat->{push_enabled}       = $fdat->{push_enabled} ? 1 : 0;
	$fdat->{condition}        ||= '';
	$fdat->{repeat}             = int($fdat->{repeat} // 0);
	$fdat->{default_snooze}     = int($fdat->{default_snooze} // 0);

	$fdat->{active_from_sec} = hhmm_to_sec($fdat->{active_from});
	$fdat->{active_to_sec}   = hhmm_to_sec($fdat->{active_to});

	# Detect changes
	my $changed = 0;
	$changed ||= (($old->{sms_notification} // '') ne ($fdat->{sms_notification} // ''));
	$changed ||= (($old->{sms_enabled} // 1) != ($fdat->{sms_enabled} // 0));
	$changed ||= (($old->{push_enabled} // 0) != ($fdat->{push_enabled} // 0));
	$changed ||= (($old->{condition} // '') ne ($fdat->{condition} // ''));
	$changed ||= (($old->{repeat} + 0) != ($fdat->{repeat} + 0));
	$changed ||= (($old->{default_snooze} + 0) != ($fdat->{default_snooze} + 0));
	$changed ||= (($old->{up_message} // '') ne ($fdat->{up_message} // ''));
	$changed ||= (($old->{down_message} // '') ne ($fdat->{down_message} // ''));
	$changed ||= (($old->{comment} // '') ne ($fdat->{comment} // ''));
	$changed ||= (($old->{active_from_sec} // 0) != ($fdat->{active_from_sec} // 0));
	$changed ||= (($old->{active_to_sec} // 0) != ($fdat->{active_to_sec} // 0));

	if ($old->{auto_id} && $old_ignore == 0 && $changed) {
		$new_ignore = 1;
	}

	# Switch back to AUTO template
	if ($old_ignore == 1 && $new_ignore == 0 && $old->{auto_id}) {
		my $aa = $dbh->selectrow_hashref("SELECT * FROM alarms_auto WHERE id = ? AND enabled = 1", undef, $old->{auto_id});
		if ($aa) {
			$fdat->{enabled}          = 1;
			$fdat->{sms_notification} = $aa->{sms_notification} || '';
			$fdat->{sms_enabled}      = defined $aa->{sms_enabled} ? $aa->{sms_enabled} : 1;
			$fdat->{push_enabled}     = defined $aa->{push_enabled} ? $aa->{push_enabled} : 0;
			$fdat->{condition}        = $aa->{condition};
			$fdat->{repeat}           = $aa->{repeat} || 0;
			$fdat->{default_snooze}   = $aa->{default_snooze} || 1800;
			$fdat->{up_message}       = $aa->{up_message} || 'normal';
			$fdat->{down_message}     = $aa->{down_message} || 'alarm';
			$fdat->{comment}          = $aa->{description} || '';
			$fdat->{active_from_sec}  = $aa->{active_from_sec};
			$fdat->{active_to_sec}    = $aa->{active_to_sec};
		}
	}

	my $new_enabled = $fdat->{enabled} ? 1 : 0;
	my $last_notification = $new_enabled ? $old->{last_notification} : undef;

	$dbh->do(qq[
		UPDATE alarms SET
			enabled = ?,
			sms_notification = ?,
			sms_enabled = ?,
			push_enabled = ?,
			`condition` = ?,
			`repeat` = ?,
			default_snooze = ?,
			up_message = ?,
			down_message = ?,
			`comment` = ?,
			active_from_sec = ?,
			active_to_sec = ?,
			ignore_auto_update = ?,
			last_notification = ?
		WHERE id = ?
	], undef,
		$new_enabled,
		$fdat->{sms_notification}, $fdat->{sms_enabled},
		$fdat->{push_enabled}, $fdat->{condition},
		$fdat->{repeat} || 0, $fdat->{default_snooze} || 0,
		$fdat->{up_message}, $fdat->{down_message},
		$fdat->{comment}, $fdat->{active_from_sec},
		$fdat->{active_to_sec}, $new_ignore,
		$last_notification, $id
	);
}

1;
