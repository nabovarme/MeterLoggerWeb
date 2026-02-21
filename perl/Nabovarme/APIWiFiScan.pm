package Nabovarme::APIWiFiScan;

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
	my ($serial) = $orig_uri =~ m{^/api/wifi_scan/([A-Za-z0-9_-]{1,16})$};
	return Apache2::Const::HTTP_BAD_REQUEST unless $serial;

	my $dbh = Nabovarme::Db->my_connect
		or return Apache2::Const::HTTP_SERVICE_UNAVAILABLE;

	$r->content_type("application/json; charset=utf-8");
	$r->headers_out->set('Cache-Control' => 'max-age=60, public');
	$r->headers_out->set('Expires' => HTTP::Date::time2str(time + 60));
	$r->err_headers_out->add("Access-Control-Allow-Origin" => '*');

	my $week_ago = time - 7*24*60*60;

	# Step 1: fetch APs seen by this serial only
	my $sth = $dbh->prepare(q{
		SELECT ssid, rssi, channel, auth_mode, pairwise_cipher, group_cipher,
		       phy_11b, phy_11g, phy_11n, wps
		FROM wifi_scan
		WHERE unix_time >= ?
		  AND serial = ?
	});
	$sth->execute($week_ago, $serial);

	# Step 2: organize by SSID
	my %aps_by_ssid;
	while (my $row = $sth->fetchrow_hashref) {
		$_ //= '' for values %$row;
		push @{ $aps_by_ssid{ $row->{ssid} } }, $row;
	}

	# Step 3: build exclusion list (meter itself + descendants)
	my %exclude;
	my $root_ssid = "mesh-$serial";

	if ($aps_by_ssid{$root_ssid}) {
		my @queue = ($root_ssid);
		while (@queue) {
			my $current = shift @queue;
			next if $exclude{$current};
			$exclude{$current} = 1;

			for my $ssid (keys %aps_by_ssid) {
				# children are SSIDs like mesh-<parent_serial>
				if ($ssid =~ /^mesh-(.+)$/ && $1 eq $current) {
					push @queue, $ssid;
				}
			}
		}
	}

	# Step 4: pick strongest AP per SSID, excluding meter's subtree
	my @result;
	for my $ssid (keys %aps_by_ssid) {
		next if $exclude{$ssid};
		my ($strongest) = sort { $b->{rssi} <=> $a->{rssi} } @{ $aps_by_ssid{$ssid} };
		push @result, $strongest if $strongest;
	}

	# Step 5: sort by RSSI descending
	@result = sort { $b->{rssi} <=> $a->{rssi} } @result;

	my $json = JSON::XS->new->utf8->canonical->encode(\@result);
	$r->print($json);

	return Apache2::Const::OK;
}

1;