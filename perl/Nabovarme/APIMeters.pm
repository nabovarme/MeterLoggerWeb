package Nabovarme::APIMeters;

use strict;
use warnings;
use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::Const -compile => qw(OK);
use DBI;
use utf8;

use lib qw( /etc/apache2/perl );
use Nabovarme::Db;
use Nabovarme::Utils;

sub handler {
	my $r = shift;
	my ($dbh, $sth, $d);

	if ($dbh = Nabovarme::Db->my_connect) {
		$r->content_type("application/json; charset=utf-8");
		$r->err_headers_out->add("Access-Control-Allow-Origin" => '*');

		$r->print("[");
		my $first_group = 1;

		# Get distinct groups
		$sth = $dbh->prepare(q[
			SELECT DISTINCT mg.id, mg.`group` AS group_name
			FROM meter_groups mg
			JOIN meters m ON mg.id = m.`group`
			WHERE m.type IN ('heat', 'heat_supply', 'heat_sub')
			ORDER BY mg.id
		]);
		$sth->execute;

		while (my $group = $sth->fetchrow_hashref) {
			my $group_id = $dbh->quote($group->{id});

			# Get meters for this group
			my $sth_meters = $dbh->prepare(qq[
				SELECT
					m.serial,
					m.info,
					m.enabled,
					latest_sc.energy,
					latest_sc.volume,
					latest_sc.hours,
					ROUND(
						IFNULL(paid_kwh_table.paid_kwh, 0) - IFNULL(latest_sc.energy, 0) + m.setup_value,
						2
					) AS kwh_left,
					ROUND(
						IF(latest_sc.effect > 0,
							(IFNULL(paid_kwh_table.paid_kwh, 0) - IFNULL(latest_sc.energy, 0) + m.setup_value) / latest_sc.effect,
							NULL
						),
						2
					) AS time_left_hours
				FROM meters m
				LEFT JOIN (
					SELECT sc.serial, sc.energy, sc.volume, sc.hours, sc.effect
					FROM samples_cache sc
					JOIN (
						SELECT serial, MAX(unix_time) AS max_time
						FROM samples_cache
						GROUP BY serial
					) latest ON sc.serial = latest.serial AND sc.unix_time = latest.max_time
				) latest_sc ON m.serial = latest_sc.serial
				LEFT JOIN (
					SELECT serial, SUM(amount / price) AS paid_kwh
					FROM accounts
					GROUP BY serial
				) paid_kwh_table ON m.serial = paid_kwh_table.serial
				WHERE m.group = $group_id
				  AND m.type IN ('heat', 'heat_supply', 'heat_sub')
				ORDER BY m.info;
				]);
			$sth_meters->execute;

			next unless $sth_meters->rows;

			$r->print(",") unless $first_group;
			$first_group = 0;

			$r->print("{");
			$r->print("\"group_name\":\"" . escape_json($group->{group_name}) . "\",");
			$r->print("\"meters\":[");

			my $first_meter = 1;
			while (my $d = $sth_meters->fetchrow_hashref) {
				# Convert hours to seconds
				my $time_left_hours = $d->{time_left_hours};
				my $time_left_seconds = (defined $time_left_hours && $time_left_hours ne '') ? $time_left_hours * 3600 : undef;

				# Human readable duration string or infinity sign
				my $time_left_hours_string = defined $time_left_seconds ? rounded_duration($time_left_seconds) : '∞';

				$r->print(",") unless $first_meter;
				$first_meter = 0;

				$r->print("{");
				$r->print(join(",", map {
					my $key = $_;
					my $val;
					if ($key eq 'time_left_hours_string') {
						$val = $time_left_hours_string;
					} elsif ($key eq 'time_left_hours') {
						$val = defined $time_left_hours ? $time_left_hours : '';
					} else {
						$val = defined $d->{$key} ? $d->{$key} : '';
					}
					"\"$key\":\"" . escape_json($val) . "\""
				} qw(serial info enabled energy volume hours kwh_left time_left_hours time_left_hours_string)));
				$r->print("}");
			}

			$r->print("]}");
		}

		$r->print("]");
		$dbh->disconnect;
	}

	return Apache2::Const::OK;
}

sub escape_json {
	my $s = shift;
	$s =~ s/\\/\\\\/g;
	$s =~ s/"/\\"/g;
	$s =~ s/\n/\\n/g;
	$s =~ s/\r/\\r/g;
	$s =~ s/\t/\\t/g;
	return $s;
}

1;
