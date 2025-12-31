package Nabovarme::APIAccount;

use strict;
use warnings;
use utf8;
use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::Const;
use JSON::XS;

use Nabovarme::Db;
use Nabovarme::Utils;
use Nabovarme::EnergyEstimator;

sub handler {
	my $r = shift;
	my $dbh = Nabovarme::Db->my_connect;
	return Apache2::Const::HTTP_SERVICE_UNAVAILABLE unless $dbh;

	# Extract serial number from URI
	my ($serial) = $r->uri =~ m|([^/]+)$|;
	return Apache2::Const::HTTP_SERVICE_UNAVAILABLE unless $serial;

	$r->content_type("application/json; charset=utf-8");

	# Disable caching
	$r->headers_out->set('Pragma' => 'no-cache');
	$r->headers_out->set('Cache-Control' => 'no-store, no-cache, must-revalidate');

	# Allow CORS
	$r->err_headers_out->add("Access-Control-Allow-Origin" => '*');

	# --- Get remaining energy/time info using utility function ---
	my $remaining = Nabovarme::EnergyEstimator::estimate_remaining_energy($dbh, $serial);

	# --- Round numeric values ---
	my $kwh_remaining = defined $remaining->{kwh_remaining} 
		? sprintf("%.0f", $remaining->{kwh_remaining}) + 0 
		: undef;

	my $time_remaining_hours = defined $remaining->{time_remaining_hours} 
		? sprintf("%.0f", $remaining->{time_remaining_hours}) + 0 
		: undef;

	my $time_remaining_hours_string = $remaining->{time_remaining_hours_string};
	if  ($remaining->{sw_version} =~ /NO_AUTO_CLOSE/ || !$remaining->{valve_installed}) {
		$time_remaining_hours_string = '∞';
	}

	my $energy_last_day = defined $remaining->{energy_last_day} 
		? sprintf("%.0f", $remaining->{energy_last_day}) + 0 
		: undef;

	my $avg_energy_last_day = defined $remaining->{avg_energy_last_day} 
		? sprintf("%.2f", $remaining->{avg_energy_last_day}) + 0 
		: undef;

	# --- Fetch latest sample data ---
	my $sth = $dbh->prepare(qq[
		SELECT hours, volume, energy
		FROM samples_cache
		WHERE serial = ?
		ORDER BY unix_time DESC
		LIMIT 1
	]);
	$sth->execute($serial);
	my ($last_hours, $last_volume, $last_energy) = $sth->fetchrow_array;

	# --- Fetch account records ---
	$sth = $dbh->prepare(qq[
		SELECT m.info, a.*
		FROM accounts a
		LEFT JOIN meters m ON a.serial = m.serial
		WHERE a.serial = ?
		ORDER BY a.payment_time ASC
	]);
	$sth->execute($serial);

	my @account;
	while (my $row = $sth->fetchrow_hashref) {
		push @account, {
			id           => $row->{id},
			type         => $row->{type},
			payment_time => $row->{payment_time},
			info         => $row->{info},
			amount       => $row->{amount},
			price        => $row->{price},
		};
	}

	# --- Construct response ---
	my $response = {
		method                      => $remaining->{method},
		kwh_remaining               => $kwh_remaining,
		time_remaining_hours        => $time_remaining_hours || 0,
		time_remaining_hours_string => $time_remaining_hours_string,
		energy_last_day             => $energy_last_day || 0,
		avg_energy_last_day         => $avg_energy_last_day || 0,
		last_hours                  => $last_hours,
		last_volume                 => $last_volume,
		last_energy                 => $last_energy,
		account                     => \@account,
	};

	my $json_obj = JSON::XS->new->utf8->canonical;
	$r->print($json_obj->encode($response));

	return Apache2::Const::OK;
}

1;
