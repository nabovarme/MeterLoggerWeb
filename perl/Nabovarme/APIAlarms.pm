package Nabovarme::APIAlarms;

use strict;
use warnings;
use utf8;
use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::Const -compile => qw(OK HTTP_SERVICE_UNAVAILABLE);
use JSON qw(encode_json);
use DBI;
use HTTP::Date qw(time2str);

use Nabovarme::Db;

sub handler {
	my $r = shift;
	my ($dbh, $sth, $d);
	
	if ($dbh = Nabovarme::Db->my_connect) {
		$r->content_type("application/json; charset=utf-8");
		# Cache for 60 seconds
		$r->headers_out->set('Cache-Control' => 'max-age=60, public');
		$r->headers_out->set('Expires' => time2str(time + 60));
		
		$r->err_headers_out->add("Access-Control-Allow-Origin" => '*');

		my @response;

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
				ORDER BY meters.info ASC, alarms.enabled DESC, alarms.condition_state DESC, alarms.sms_notification ASC
			]);
			$sth_alarms->execute;

			# Skip groups with no alarms
			next unless $sth_alarms->rows;

			my @alarms;

			while ($d = $sth_alarms->fetchrow_hashref) {
				my $alarm_data = prepare_alarm_data($d);
				push @alarms, $alarm_data;
			}

			push @response, {
				group_name => $group->{group},
				alarms => \@alarms
			};
		}

		# Fetch orphan alarms (no corresponding meter)
		my $sth_orphans = $dbh->prepare(q[
			SELECT alarms.*
			FROM alarms
			LEFT JOIN meters ON alarms.serial = meters.serial
			WHERE meters.serial IS NULL
			ORDER BY alarms.condition_state DESC, alarms.sms_notification ASC
		]);
		$sth_orphans->execute;

		if ($sth_orphans->rows) {
			my @orphans;

			while ($d = $sth_orphans->fetchrow_hashref) {
				my $alarm_data = prepare_alarm_data($d);
				push @orphans, $alarm_data;
			}

			push @response, {
				group_name => "Orphans",
				alarms => \@orphans
			};
		}

		$r->print(encode_json(\@response));

		return Apache2::Const::OK;
	}

	$r->err_headers_out->set('Retry-After' => '60');

	return Apache2::Const::HTTP_SERVICE_UNAVAILABLE;
}

sub prepare_alarm_data {
	my ($alarm) = @_;

	return {
		id => $alarm->{id} // '',
		serial => $alarm->{serial} // '',
		info => $alarm->{info} // '',
		alarm_state => $alarm->{alarm_state} // '',
		condition_state => $alarm->{condition_state} // '',
		enabled => $alarm->{enabled} // '',
		in_active_window => $alarm->{in_active_window} // '',
		condition => $alarm->{condition} // '',
		condition_error => $alarm->{condition_error} // '',
		sms_notification => $alarm->{sms_notification} // '',
		comment => $alarm->{comment} // '',
		repeat => $alarm->{repeat} // '',
		snooze => $alarm->{snooze} // '',
		active_from_sec => $alarm->{active_from_sec} // '',
		active_to_sec => $alarm->{active_to_sec} // '',
		timezone => $alarm->{timezone} // '',
	};
}

1;

__END__
