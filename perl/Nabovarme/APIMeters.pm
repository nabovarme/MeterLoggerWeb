package Nabovarme::APIMeters;

use strict;
use warnings;
use utf8;
use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::Const -compile => qw(OK HTTP_SERVICE_UNAVAILABLE);
use JSON::XS;

use lib qw( /etc/apache2/perl );
use Nabovarme::Db;
use Nabovarme::Utils;

sub handler {
	my $r = shift;
	my $dbh = Nabovarme::Db->my_connect;
	return Apache2::Const::HTTP_SERVICE_UNAVAILABLE unless $dbh;

	$r->content_type("application/json; charset=utf-8");
	$r->headers_out->set('Cache-Control' => 'max-age=60, public');
	$r->headers_out->set('Expires' => HTTP::Date::time2str(time + 60));
	$r->err_headers_out->add("Access-Control-Allow-Origin" => '*');

	my $sth = $dbh->prepare(qq[
		SELECT mg.`group` AS meter_group, mg.`id` AS group_id, m.*
		FROM meters m
		JOIN meter_groups mg ON m.`group` = mg.`id`
		WHERE m.type IN ('heat', 'heat_supply', 'heat_sub')
		ORDER BY mg.`id`, m.info
	]);
	$sth->execute();

	my @groups;
	my ($current_group_id, $current_group);

	while (my $row = $sth->fetchrow_hashref) {
		# Start new group if changed
		if (!defined $current_group_id || $current_group_id != $row->{group_id}) {
			$current_group_id = $row->{group_id};
			$current_group = { group_name => $row->{meter_group}, meters => [] };
			push @groups, $current_group;
		}

		# --- Calculate remaining energy and time using utility function ---
		my $remaining = Nabovarme::Utils::estimate_remaining_energy($dbh, $row->{serial});

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
			kwh_remaining				=> $remaining->{kwh_remaining},
			time_remaining_hours		=> $remaining->{time_remaining_hours},
			time_remaining_hours_string => $remaining->{time_remaining_hours_string},
			energy_last_day				=> $remaining->{energy_last_day},
			avg_energy_last_day			=> $remaining->{avg_energy_last_day},
		};
	}

	my $json_obj = JSON::XS->new->utf8->canonical;
	$r->print($json_obj->encode(\@groups));

	return Apache2::Const::OK;
}

1;
