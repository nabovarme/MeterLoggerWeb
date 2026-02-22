package Nabovarme::APIWiFiMeshRSSI;

use strict;
use warnings;
use utf8;
use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::Const -compile => qw(OK HTTP_BAD_REQUEST HTTP_SERVICE_UNAVAILABLE);
use HTTP::Date;
use JSON::XS ();

use Nabovarme::Db;

sub handler {
	my $r = shift;

	my $orig_uri = $r->unparsed_uri || $r->uri;
	my ($serial) = $orig_uri =~ m{^/api/wifi_mesh_rssi/([A-Za-z0-9_-]{1,16})$};
	return Apache2::Const::HTTP_BAD_REQUEST unless $serial;

	my $dbh = Nabovarme::Db->my_connect
		or return Apache2::Const::HTTP_SERVICE_UNAVAILABLE;

	$r->content_type("application/json; charset=utf-8");
	$r->err_headers_out->add("Access-Control-Allow-Origin" => '*');

	# Get SSID this serial is currently connected to
	my ($current_ssid) = $dbh->selectrow_array(
		"SELECT ssid FROM meters WHERE serial = ?",
		undef, $serial
	);

	unless (defined $current_ssid && $current_ssid ne '') {
		my $json = JSON::XS->new->utf8->canonical->encode({
			serial => $serial,
			error  => "No current SSID"
		});
		$r->print($json);
		return Apache2::Const::OK;
	}

	my $min_rssi;
	my @chain;
	my $hop = 0;

	my $current_serial = $serial;

	while (1) {

		# Get current SSID and RSSI
		my ($ssid, $rssi) = $dbh->selectrow_array(
			"SELECT ssid, rssi FROM meters WHERE serial = ?",
			undef, $current_serial
		);

		last unless defined $ssid && $ssid ne '';

		if (defined $rssi) {
			$hop++;

			$min_rssi = $rssi
				if !defined($min_rssi) || $rssi < $min_rssi;

			push @chain, {
				serial => $current_serial,
				ssid   => $ssid,
				rssi   => $rssi,
				hop    => $hop
			};
		}

		# If parent is mesh-<serial>, continue upstream
		if ($ssid =~ /^mesh-(.*)$/) {
			$current_serial = $1;
		} else {
			# Reached root AP (non-mesh SSID)
			last;
		}
	}

	my $json = JSON::XS->new->utf8->canonical->encode({
		serial        => $serial,
		weakest_rssi  => $min_rssi,
		hop_count     => $hop,
		chain         => \@chain
	});

	$r->print($json);

	return Apache2::Const::OK;
}

1;