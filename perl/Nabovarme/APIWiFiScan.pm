package Nabovarme::APIWiFiScan;

use strict;
use warnings;
use utf8;

use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::RequestUtil ();
use Apache2::Const -compile => qw(OK HTTP_BAD_REQUEST HTTP_SERVICE_UNAVAILABLE);

use APR::Table ();
use HTTP::Date;
use JSON::XS;

use Nabovarme::Db;
use Data::Dumper;

sub handler {
	my $r = shift;
	my ($dbh, $sth);

	# Extract into auth and optional snooze
	my $orig_uri = $r->unparsed_uri || $r->uri;
	
	my $serial;
	if ($orig_uri =~ m{^/api/wifi_scan/(\d+)$}) {
		$serial = $1;
	}

	# Basic validation (16 char max, alnum only)
	unless ($serial =~ /^[A-Za-z0-9_-]{1,16}$/) {
		return Apache2::Const::HTTP_BAD_REQUEST;
	}

	if ($dbh = Nabovarme::Db->my_connect) {

		$r->content_type("application/json; charset=utf-8");

		# Cache for 60 seconds
		$r->headers_out->set('Cache-Control' => 'max-age=60, public');
		$r->headers_out->set('Expires' => HTTP::Date::time2str(time + 60));
		$r->err_headers_out->add("Access-Control-Allow-Origin" => '*');

		# Calculate timestamp for one week ago
		my $week_ago = time - 7*24*60*60;

		# Get distinct APs seen in the last week
		my $sql = q[
			SELECT
				ssid,
				bssid,
				MAX(rssi) AS rssi,
				MAX(channel) AS channel,
				MAX(auth_mode) AS auth_mode,
				MAX(pairwise_cipher) AS pairwise_cipher,
				MAX(group_cipher) AS group_cipher,
				MAX(phy_11b) AS phy_11b,
				MAX(phy_11g) AS phy_11g,
				MAX(phy_11n) AS phy_11n,
				MAX(wps) AS wps
			FROM wifi_scan
			WHERE serial = ?
			  AND unix_time >= ?
			GROUP BY bssid, ssid
			ORDER BY rssi DESC
			LIMIT 50
		];

		$sth = $dbh->prepare($sql);
		$sth->execute($serial, $week_ago);

		my @rows;

		while (my $row = $sth->fetchrow_hashref) {

			# Avoid undef in JSON
			$_ //= '' for values %$row;

			push @rows, $row;
		}

		my $json = JSON::XS->new->utf8->canonical;
		$r->print($json->encode(\@rows));

		return Apache2::Const::OK;
	}

	$r->err_headers_out->set('Retry-After' => '60');
	return Apache2::Const::HTTP_SERVICE_UNAVAILABLE;
}

1;