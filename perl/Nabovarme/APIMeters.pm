package Nabovarme::APIMeters;

use strict;
use warnings;
use utf8;
use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::Const -compile => qw(OK);
use DBI;
use JSON::XS;

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
				m.*,
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

		my @groups;
		my $current_group_id;
		my $current_group;

		while (my $row = $sth->fetchrow_hashref) {
			# Start new group when group_id changes
			if (!defined $current_group_id || $current_group_id != $row->{group_id}) {
				$current_group_id = $row->{group_id};
				$current_group = {
					group_name => $row->{meter_group},
					meters    => [],
				};
				push @groups, $current_group;
			}

			# Convert time_left_hours to string and seconds as before
			my $time_left_hours = $row->{time_left_hours};
			my $time_left_hours_string;
			if ($time_left_hours) {
				$time_left_hours_string = rounded_duration($time_left_hours * 3600);
			} else {
				$time_left_hours_string = '∞';
			}

			# Add meter data hashref
			push @{ $current_group->{meters} }, {
				serial                 => $row->{serial} // '',
				info                   => $row->{info} // '',
				enabled                => $row->{enabled} // '',
				energy                 => defined $row->{energy} ? int($row->{energy}) : '',
				volume                 => defined $row->{volume} ? int($row->{volume}) : '',
				hours                  => $row->{hours} // '',
				kwh_left               => defined $row->{kwh_left} ? int($row->{kwh_left}) : '',
				time_left_hours        => defined $time_left_hours ? $time_left_hours : '',
				time_left_hours_string => $time_left_hours_string,
			};
		}

		# Encode final data structure to JSON using JSON module with utf8 encoding
		my $json_obj = JSON::XS->new->utf8->canonical;
		my $json_text = $json_obj->encode(\@groups);

		$r->print($json_text);

		$dbh->disconnect;
	}

	return Apache2::Const::OK;
}

1;
