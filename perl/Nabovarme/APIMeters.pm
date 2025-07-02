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
	my ($dbh, $sth);

	if ($dbh = Nabovarme::Db->my_connect) {
		$r->content_type("application/json; charset=utf-8");
		$r->err_headers_out->add("Access-Control-Allow-Origin" => '*');

		my $sql = q[
			SELECT
				mg.`group` AS meter_group,
				mg.`id` AS group_id,
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
				) AS time_left_hours,
				latest_sc.unix_time AS last_sample_time
			FROM meters m
			JOIN meter_groups mg ON m.`group` = mg.`id`
			LEFT JOIN (
				SELECT sc1.*
				FROM samples_cache sc1
				INNER JOIN (
					SELECT serial, MAX(unix_time) AS max_time
					FROM samples_cache
					GROUP BY serial
				) latest ON sc1.serial = latest.serial AND sc1.unix_time = latest.max_time
			) latest_sc ON m.serial = latest_sc.serial
			LEFT JOIN (
				SELECT serial, SUM(amount / price) AS paid_kwh
				FROM accounts
				GROUP BY serial
			) paid_kwh_table ON m.serial = paid_kwh_table.serial
			WHERE m.type IN ('heat', 'heat_supply', 'heat_sub')
			ORDER BY mg.`id`, m.info
		];

		$sth = $dbh->prepare($sql);
		$sth->execute();

		$r->print("[");
		my $current_group_id;
		my $first_group = 1;
		my $first_meter;

		while (my $row = $sth->fetchrow_hashref) {
			# Start new group JSON object when group_id changes
			if (!defined $current_group_id || $current_group_id != $row->{group_id}) {
				$r->print("]}")
					if defined $current_group_id; # close previous group array and object

				$r->print(",") unless $first_group;
				$first_group = 0;
				$current_group_id = $row->{group_id};
				$r->print("{");
				$r->print("\"group_name\":\"" . escape_json($row->{meter_group}) . "\",");
				$r->print("\"meters\":[");
				$first_meter = 1;
			}

			$r->print(",") unless $first_meter;
			$first_meter = 0;

			# Convert time_left_hours to string and seconds as before
			my $time_left_hours = $row->{time_left_hours};
			my $time_left_hours_string;
			if ($time_left_hours) {
				$time_left_hours_string = rounded_duration($time_left_hours * 3600);
			}
			else {
				$time_left_hours_string = '∞';
			}

			$r->print("{");
			$r->print(join(",", map {
				my $key = $_;
				my $val;
				if ($key eq 'time_left_hours_string') {
					$val = $time_left_hours_string;
				} elsif ($key eq 'time_left_hours') {
					$val = defined $time_left_hours ? $time_left_hours : '';
				} elsif ($key =~ /^(energy|volume|kwh_left)$/) {
					$val = defined $row->{$key} ? int($row->{$key}) : '';
				} else {
					$val = defined $row->{$key} ? $row->{$key} : '';
				}
				"\"$key\":\"" . escape_json($val) . "\""
			} qw(serial info enabled energy volume hours kwh_left time_left_hours time_left_hours_string)));
			$r->print("}");
		}

		# Close last group's meters array and group object
		$r->print("]}") if defined $current_group_id;

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
