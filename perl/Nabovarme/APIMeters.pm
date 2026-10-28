package Nabovarme::APIMeters;

use strict;
use warnings;
use utf8;
use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::Const -compile => qw(OK HTTP_SERVICE_UNAVAILABLE);
use HTTP::Date;
use JSON ();

use Nabovarme::Db;
use Nabovarme::Utils;

sub handler {
	my $r = shift;
	my ($dbh, $sth);

	# Connect to DB
	if ($dbh = Nabovarme::Db->my_connect) {
		$r->content_type("application/json; charset=utf-8");
		$r->headers_out->set('Cache-Control' => 'max-age=60, public');
		$r->headers_out->set('Expires' => HTTP::Date::time2str(time + 60));
		$r->err_headers_out->add("Access-Control-Allow-Origin" => '*');

		# --- Fetch meters and join with meters_state for kwh_remaining/time_remaining_hours_string ---
		my $sql = q[
		SELECT
			mg.`group` AS meter_group,
			mg.`id` AS group_id,
			m.serial,
			m.info,
			m.enabled,
			m.sw_version,
			m.valve_status,
			m.valve_installed,
			m.last_updated,
			m.rssi,
			m.wifi_status,
			m.ap_status,
			m.uptime,
			m.reset_reason,
			m.ssid,
			m.location_lat,
			m.location_long,
			m.flash_id,
			m.flash_size,
			m.ping_response_time,
			m.ping_average_packet_loss,
			m.disconnect_count,
			m.comment,
			latest_sc.energy,
			latest_sc.volume,
			latest_sc.hours,
			s.kwh_remaining,
			s.time_remaining_hours,
			s.time_remaining_hours_string,
			ROUND(latest_sc.energy - prev_sc.energy, 2) AS energy_last_day,
			ROUND((latest_sc.energy - prev_sc.energy) / 24, 2) AS avg_energy_last_day,
			latest_sc.unix_time AS last_sample_time

		FROM meters m
		JOIN meter_groups mg ON m.`group` = mg.`id`

		LEFT JOIN (
			SELECT sc1.*
			FROM samples_cache sc1
			INNER JOIN (
				SELECT sc.serial, MAX(sc.id) AS id
				FROM samples_cache sc
				INNER JOIN (
					SELECT serial, MAX(unix_time) AS max_time
					FROM samples_cache
					GROUP BY serial
				) latest ON sc.serial = latest.serial
					AND sc.unix_time = latest.max_time
				GROUP BY sc.serial
			) latest ON sc1.id = latest.id
		) latest_sc ON m.serial = latest_sc.serial

		LEFT JOIN (
			SELECT sc2.*
			FROM samples_cache sc2
			INNER JOIN (
				SELECT sc.serial, MAX(sc.id) AS id
				FROM samples_cache sc
				INNER JOIN (
					SELECT serial, MAX(unix_time) AS max_time
					FROM samples_cache
					WHERE unix_time <= UNIX_TIMESTAMP(NOW()) - 86400
					GROUP BY serial
				) prev ON sc.serial = prev.serial
					AND sc.unix_time = prev.max_time
				GROUP BY sc.serial
			) prev ON sc2.id = prev.id
		) prev_sc ON m.serial = prev_sc.serial

		LEFT JOIN (
			SELECT
				serial,
				kwh_remaining,
				time_remaining_hours,
				time_remaining_hours_string
			FROM meters_state
		) s ON m.serial = s.serial

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

			# Determine if time remaining should be infinite
			my $time_remaining_hours_string = $row->{time_remaining_hours_string} || '∞';
			if (($row->{sw_version} // '') =~ /NO_AUTO_CLOSE/ || !$row->{valve_installed}) {
				$time_remaining_hours_string = '∞';
			}
			
			my $time_remaining_hours =  $row->{time_remaining_hours};
			if ($row->{valve_installed} && ($row->{valve_status} eq 'close')) {
				$time_remaining_hours = 0;
			}
			else {
				$time_remaining_hours = defined $row->{time_remaining_hours}
					? sprintf("%.0f", $row->{time_remaining_hours}) + 0 
					: undef;
			}

			my $reset_reason = $row->{reset_reason} || '';
			$reset_reason = join(' ', split(/&/, $reset_reason));
	
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
				reset_reason				=> $reset_reason,
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
				time_remaining_hours		=> $time_remaining_hours,
				time_remaining_hours_string	=> $time_remaining_hours_string,
				energy_last_day				=> $row->{energy_last_day} || 0,
				avg_energy_last_day			=> $row->{avg_energy_last_day} || 0,
			};
		}

		$r->print(
			JSON->new->utf8->canonical->encode(\@groups)
		);

		return Apache2::Const::OK;
	}

	$r->err_headers_out->set('Retry-After' => '60');
	return Apache2::Const::HTTP_SERVICE_UNAVAILABLE;
}

1;
