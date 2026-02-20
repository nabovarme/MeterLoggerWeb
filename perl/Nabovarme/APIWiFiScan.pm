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

		# Get latest scan timestamp for this meter (uses serial_unix_time_idx)
		my $latest_sql = q[
			SELECT unix_time
			FROM wifi_scan
			WHERE serial = ?
			ORDER BY unix_time DESC
			LIMIT 1
		];

		$sth = $dbh->prepare($latest_sql);
		$sth->execute($serial);

		my ($latest) = $sth->fetchrow_array;

		my @rows;

		if ($latest) {

			my $sql = q[
				SELECT
					ssid,
					bssid,
					rssi,
					channel,
					auth_mode,
					pairwise_cipher,
					group_cipher,
					phy_11b,
					phy_11g,
					phy_11n,
					wps
				FROM wifi_scan
				WHERE serial = ?
				  AND unix_time = ?
				ORDER BY rssi DESC
				LIMIT 50
			];

			$sth = $dbh->prepare($sql);
			$sth->execute($serial, $latest);

			while (my $row = $sth->fetchrow_hashref) {

				# Avoid undef in JSON
				$_ //= '' for values %$row;

				push @rows, $row;
			}
		}

		my $json = JSON::XS->new->utf8->canonical;
		$r->print($json->encode(\@rows));

		return Apache2::Const::OK;
	}

	$r->err_headers_out->set('Retry-After' => '60');
	return Apache2::Const::HTTP_SERVICE_UNAVAILABLE;
}

1;