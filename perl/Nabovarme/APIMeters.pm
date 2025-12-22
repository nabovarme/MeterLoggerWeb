package Nabovarme::APIMeters;

use strict;
use warnings;
use utf8;
use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::Const -compile => qw(OK HTTP_SERVICE_UNAVAILABLE);
use HTTP::Date;
use JSON::XS;

use lib qw( /etc/apache2/perl );
use Nabovarme::Db;
use Nabovarme::Utils;

sub handler {
	my $r = shift;
	my ($dbh, $sth);

	if ($dbh = Nabovarme::Db->my_connect) {
		$r->content_type("application/json; charset=utf-8");
		$r->headers_out->set('Cache-Control' => 'max-age=60, public');
		$r->headers_out->set('Expires' => HTTP::Date::time2str(time + 60));
		$r->err_headers_out->add("Access-Control-Allow-Origin" => '*');

		my $sql = q[
		SELECT
			mg.`group` AS meter_group,
			mg.`id` AS group_id,
			m.*,
			latest_sc.energy,
			latest_sc.volume,
			latest_sc.hours,

			ROUND(latest_sc.energy - prev_sc.energy, 2) AS energy_last_day,
			ROUND((latest_sc.energy - prev_sc.energy) / 24, 2) AS avg_energy_last_day,

			ROUND(
				IFNULL(paid_kwh_table.paid_kwh, 0) - IFNULL(latest_sc.energy, 0) + m.setup_value,
				2
			) AS kwh_remaining,

			m.time_remaining_hours_string,

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
			SELECT sc2.*
			FROM samples_cache sc2
			INNER JOIN (
				SELECT serial, MAX(unix_time) AS max_time
				FROM samples_cache
				WHERE unix_time <= UNIX_TIMESTAMP(NOW()) - 86400
				GROUP BY serial
			) prev ON sc2.serial = prev.serial AND sc2.unix_time = prev.max_time
		) prev_sc ON m.serial = prev_sc.serial

		LEFT JOIN (
			SELECT serial, SUM(amount / price) AS paid_kwh
			FROM accounts
			GROUP BY serial
		) paid_kwh_table ON m.serial = paid_kwh_table.serial

		WHERE m.type IN ('heat', 'heat_supply', 'heat_sub')
		ORDER BY mg.`id`, m.info;
		];

		$sth = $dbh->prepare($sql);
		$sth->execute();

		my @groups;
		my $current_group_id;
		my $current_group;

		while (my $row = $sth->fetchrow_hashref) {
			if (!defined $current_group_id || $current_group_id != $row->{group_id}) {
				$current_group_id = $row->{group_id};
				$current_group = {
					group_name	=> $row->{meter_group},
					meters		=> [],
				};
				push @groups, $current_group;
			}

			push @{ $current_group->{meters} }, {
				serial						=> $row->{serial} || '',
				info						=> $row->{info} || '',
				enabled						=> $row->{enabled} || 0,
				sw_version					=> $row->{sw_version} || '',
				valve_status				=> $row->{valve_status} || '',
				valve_installed				=> $row->{valve_installed} || 0,
				last_updated				=> $row->{last_updated} || 0,
				rssi						=> $row->{rssi} || 0,
				wifi_status					=> $row->{wifi_status} || '',
				ap_status					=> $row->{ap_status} || '',
				uptime						=> $row->{uptime} || 0,
				reset_reason				=> $row->{reset_reason} || '',
				ssid						=> $row->{ssid} || '',
				location_lat				=> $row->{location_lat} || '',
				location_long				=> $row->{location_long} || '',
				flash_id					=> $row->{flash_id} || '',
				flash_size					=> $row->{flash_size} || '',
				ping_response_time			=> $row->{ping_response_time} || '',
				ping_average_packet_loss	=> $row->{ping_average_packet_loss} || '',
				disconnect_count			=> $row->{disconnect_count} || 0,
				comment						=> $row->{comment} || '',
				energy						=> defined $row->{energy} ? int($row->{energy}) : 0,
				volume						=> defined $row->{volume} ? int($row->{volume}) : 0,
				hours						=> $row->{hours} || 0,
				kwh_remaining				=> defined $row->{kwh_remaining} ? int($row->{kwh_remaining}) : 0,
				time_remaining_hours_string	=> $row->{time_remaining_hours_string} || '∞',
				energy_last_day				=> $row->{energy_last_day} || 0,
				avg_energy_last_day			=> $row->{avg_energy_last_day} || 0,
			};
		}

		my $json_obj = JSON::XS->new->utf8->canonical;
		$r->print($json_obj->encode(\@groups));

		return Apache2::Const::OK;
	}

	$r->err_headers_out->set('Retry-After' => '60');
	return Apache2::Const::HTTP_SERVICE_UNAVAILABLE;
}

1;
