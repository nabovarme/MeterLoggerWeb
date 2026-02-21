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

	# Step 1: fetch all APs seen by this serial
	my $sth = $dbh->prepare(q{
		SELECT ssid, rssi, channel, auth_mode, pairwise_cipher, group_cipher,
		       phy_11b, phy_11g, phy_11n, wps
		FROM wifi_scan
		WHERE unix_time >= ?
		  AND serial = ?
	});
	$sth->execute($week_ago, $serial);

	my %aps_by_ssid;
	while (my $row = $sth->fetchrow_hashref) {
		$_ //= '' for values %$row;
		push @{ $aps_by_ssid{ $row->{ssid} } }, $row;
	}

	# Step 2: build recursive exclusion list
	my %exclude;
	my $root_ap = "mesh-$serial";

	# exclude the meter's own AP
	$exclude{$root_ap} = 1;

	# exclude the SSID the meter is currently connected to
	my $sth_ssid = $dbh->prepare("SELECT ssid FROM meters WHERE serial = ?");
	$sth_ssid->execute($serial);
	my ($current_ssid) = $sth_ssid->fetchrow_array;
	$exclude{$current_ssid} = 1 if $current_ssid;

	# recursively exclude all descendants
	my @queue = ($serial);  # queue of serials
	while (@queue) {
		my $parent_serial = shift @queue;

		# find all meters connected to this parent
		my $sth_children = $dbh->prepare("SELECT serial FROM meters WHERE ssid = ?");
		$sth_children->execute("mesh-$parent_serial");

		while (my ($child_serial) = $sth_children->fetchrow_array) {
			my $child_ap = "mesh-$child_serial";
			next if $exclude{$child_ap};
			$exclude{$child_ap} = 1;     # exclude the child’s AP
			push @queue, $child_serial;  # recurse into the child
		}
	}

	# Step 3: pick strongest AP per SSID, excluding all in %exclude
	my @result;
	for my $ssid (keys %aps_by_ssid) {
		next if $exclude{$ssid};
		my ($strongest) = sort { $b->{rssi} <=> $a->{rssi} } @{ $aps_by_ssid{$ssid} };
		push @result, $strongest if $strongest;
	}

	# Step 4: sort by RSSI descending
	@result = sort { $b->{rssi} <=> $a->{rssi} } @result;

	my $json = JSON::XS->new->utf8->canonical->encode(\@result);
	$r->print($json);

	return Apache2::Const::OK;
}

1;