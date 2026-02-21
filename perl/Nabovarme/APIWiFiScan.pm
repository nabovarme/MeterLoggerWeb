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

	# Step 1: fetch all APs seen by this serial in the last week
	my $sth = $dbh->prepare(q{
		SELECT ssid, rssi, channel, auth_mode, pairwise_cipher, group_cipher,
		       phy_11b, phy_11g, phy_11n, wps, unix_time
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

	# Step 2: build recursive exclusion list of children
	my %exclude;
	my @queue = ($serial);
	while (@queue) {
		my $parent_serial = shift @queue;
		my $sth_children = $dbh->prepare("SELECT serial FROM meters WHERE ssid = ?");
		$sth_children->execute("mesh-$parent_serial");

		while (my ($child_serial) = $sth_children->fetchrow_array) {
			my $child_ap = "mesh-$child_serial";
			next if $exclude{$child_ap};
			$exclude{$child_ap} = 1;
			push @queue, $child_serial;
			warn "DEBUG: Excluding child serial=$child_serial of parent=$parent_serial";
		}
	}

	# Step 3: compute weakest RSSI along upstream for all mesh APs visible in wifi_scan
	my %mesh_min_rssi;
	for my $ssid (keys %aps_by_ssid) {
		next unless $ssid =~ /^mesh-/;
		for my $entry (@{ $aps_by_ssid{$ssid} }) {
			my ($node_serial) = $ssid =~ /^mesh-(.*)$/;
			warn "DEBUG: Starting upstream RSSI traversal for mesh node $node_serial";

			my $min_rssi;
			my @chain;
			my $current_serial = $node_serial;

			while ($current_serial) {
				my $current_ssid = "mesh-$current_serial";

				# Only consider RSSI if this serial has seen it
				my $entry_ref = $aps_by_ssid{$current_ssid} ? $aps_by_ssid{$current_ssid}[0] : undef;
				my $rssi = $entry_ref ? $entry_ref->{rssi} : undef;

				unless (defined $rssi) {
					warn "DEBUG: Serial $serial has not seen node $current_serial, stopping traversal";
					last;
				}

				if (!defined $min_rssi || $rssi < $min_rssi) {
					$min_rssi = $rssi;
					warn "DEBUG: New min_rssi=$min_rssi at node $current_serial";
				} else {
					warn "DEBUG: Node $current_serial has rssi=$rssi, current min_rssi=$min_rssi";
				}

				push @chain, "$current_serial($rssi)";

				# Next upstream node
				my ($parent_serial) = $dbh->selectrow_array(
					"SELECT REPLACE(ssid,'mesh-','') FROM meters WHERE serial = ?",
					undef, $current_serial
				);

				last unless defined $parent_serial && $parent_serial ne '';
				$current_serial = $parent_serial;
			}

			$mesh_min_rssi{$ssid} = $min_rssi;
			warn "DEBUG: Full upstream chain for $node_serial: " . join(" -> ", @chain);
			warn "DEBUG: Weakest RSSI for mesh node $node_serial is $min_rssi";
		}
	}

	# Step 4: pick AP per SSID
	my @result;
	for my $ssid (keys %aps_by_ssid) {
		next if $exclude{$ssid};
		my $entries = $aps_by_ssid{$ssid};

		if ($ssid =~ /^mesh-/) {
			my $base_entry = { %{ $entries->[0] } };
			$base_entry->{rssi} = $mesh_min_rssi{$ssid} if defined $mesh_min_rssi{$ssid};
			push @result, $base_entry;
			warn "DEBUG: Mesh AP $ssid, original_rssi=$entries->[0]{rssi}, weakest_upstream_rssi=$base_entry->{rssi}, included=1";
		} else {
			my ($latest_entry) = sort { $b->{unix_time} <=> $a->{unix_time} } @$entries;
			push @result, $latest_entry if $latest_entry;
			warn "DEBUG: Regular AP $latest_entry->{ssid}, original_rssi=$latest_entry->{rssi}, included=1" if $latest_entry;
		}
	}

	# Step 5: sort final results by RSSI descending
	@result = sort { $b->{rssi} <=> $a->{rssi} } @result;

	my $json = JSON::XS->new->utf8->canonical->encode(\@result);
	$r->print($json);

	return Apache2::Const::OK;
}

1;