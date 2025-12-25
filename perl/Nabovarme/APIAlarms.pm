package Nabovarme::APIAlarms;

use strict;
use warnings;
use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::Const -compile => qw(OK HTTP_SERVICE_UNAVAILABLE);
use DBI;
use utf8;

use Nabovarme::Db;

sub handler {
	my $r = shift;
	my ($dbh, $sth, $d);
	
	if ($dbh = Nabovarme::Db->my_connect) {
		$r->content_type("application/json; charset=utf-8");
		# Cache for 60 seconds
		$r->headers_out->set('Cache-Control' => 'max-age=60, public');
		$r->headers_out->set('Expires' => HTTP::Date::time2str(time + 60));
		
		$r->err_headers_out->add("Access-Control-Allow-Origin" => '*');
		
		$r->print("[");
		my $first_group = 1;

		# Fetch groups except orphans
		$sth = $dbh->prepare(q[
			SELECT id, `group` FROM meter_groups ORDER BY `id`
		]);
		$sth->execute;

		while (my $group = $sth->fetchrow_hashref) {
			my $group_id = $dbh->quote($group->{id});

			# Fetch alarms for this group
			my $sth_alarms = $dbh->prepare(qq[
				SELECT alarms.*, meters.info
				FROM alarms
				JOIN meters ON alarms.serial = meters.serial
				WHERE meters.group = $group_id
				ORDER BY meters.info ASC, alarms.enabled DESC, alarms.alarm_state DESC, alarms.sms_notification ASC
			]);
			$sth_alarms->execute;

			# Skip groups with no alarms
			next unless $sth_alarms->rows;

			# Print comma before group if not first
			$r->print(",") if !$first_group;
			$first_group = 0;

			$r->print("{");
			$r->print("\"group_name\":\"" . escape_json($group->{group}) . "\",");
			$r->print("\"alarms\":[");

			my $first_alarm = 1;
			while ($d = $sth_alarms->fetchrow_hashref) {
				$r->print(",") if !$first_alarm;
				$first_alarm = 0;

				my $alarm_data = prepare_alarm_data($d);
				$r->print("{");
				my @fields = keys %$alarm_data;
				for my $i (0 .. $#fields) {
					my $field = $fields[$i];
					my $val = defined $alarm_data->{$field} ? $alarm_data->{$field} : '';
					$r->print("\"$field\":\"" . escape_json($val) . "\"");
					$r->print(",") if $i < $#fields;
				}
				$r->print("}");
			}
			$r->print("]}");
		}

		# Fetch orphan alarms (no corresponding meter)
		my $sth_orphans = $dbh->prepare(q[
			SELECT alarms.*
			FROM alarms
			LEFT JOIN meters ON alarms.serial = meters.serial
			WHERE meters.serial IS NULL
			ORDER BY alarms.alarm_state DESC, alarms.sms_notification ASC
		]);
		$sth_orphans->execute;

		if ($sth_orphans->rows) {
			$r->print(",") if !$first_group;  # print comma if not first group
			$r->print("{\"group_name\":\"Orphans\",\"alarms\":[");
			
			my $first_orphan = 1;
			while ($d = $sth_orphans->fetchrow_hashref) {
				$r->print(",") if !$first_orphan;
				$first_orphan = 0;

				my $alarm_data = prepare_alarm_data($d);
				$r->print("{");
				my @fields = keys %$alarm_data;
				for my $i (0 .. $#fields) {
					my $field = $fields[$i];
					my $val = defined $alarm_data->{$field} ? $alarm_data->{$field} : '';
					$r->print("\"$field\":\"" . escape_json($val) . "\"");
					$r->print(",") if $i < $#fields;
				}
				$r->print("}");
			}
			$r->print("]}");
		}

		$r->print("]");

		return Apache2::Const::OK;
	}

	$r->err_headers_out->set('Retry-After' => '60');

	return Apache2::Const::HTTP_SERVICE_UNAVAILABLE;
}

sub prepare_alarm_data {
	my ($alarm) = @_;
	return {
		id => $alarm->{id} || '',
		serial => $alarm->{serial} || '',
		info => $alarm->{info} || '',
		sms_notification => $alarm->{sms_notification} || '',
		condition => $alarm->{condition} || '',
		condition_error => $alarm->{condition_error} || '',
		alarm_state => $alarm->{alarm_state} || '',
		enabled => $alarm->{enabled} || '',
		repeat => $alarm->{repeat} || '',
		snooze => $alarm->{snooze} || '',
		comment => $alarm->{comment} || '',
	};
}

sub escape_json {
	my ($str) = @_;
	return '' unless defined $str;
	$str =~ s/\\/\\\\/g;
	$str =~ s/"/\\"/g;
	$str =~ s/\n/\\n/g;
	$str =~ s/\r/\\r/g;
	$str =~ s/\t/\\t/g;
	return $str;
}

1;

__END__
