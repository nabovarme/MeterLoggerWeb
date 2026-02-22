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
		}
	}

	# Step 3: compute upstream weakest RSSI along the mesh chain
	my %mesh_min_rssi;

	for my $ssid (keys %aps_by_ssid) {
		next unless $ssid =~ /^mesh-/;

		my ($node_serial) = $ssid =~ /^mesh-(.*)$/;
		my $first_entry_ref = $aps_by_ssid{$ssid}[0];

		unless (defined $first_entry_ref && defined $first_entry_ref->{rssi}) {
			warn "VISIBILITY: Node $node_serial has no first hop wifi_scan RSSI, skipping";
			next;
		}

		my $min_rssi = $first_entry_ref->{rssi};
		my @chain = ("$node_serial($min_rssi)");

		my $current_serial = $node_serial;

		while (1) {
			# Find parent serial from meters
			my ($parent_serial) = $dbh->selectrow_array(
				"SELECT REPLACE(ssid,'mesh-','') FROM meters WHERE serial = ?",
				undef, $current_serial
			);
			last unless defined $parent_serial && $parent_serial ne '';

			# Get the RSSI of the child connecting to this parent
			my ($child_to_parent_rssi) = $dbh->selectrow_array(
				"SELECT rssi FROM meters WHERE serial = ? AND ssid = ?",
				undef, $current_serial, "mesh-$parent_serial"
			);

			if (defined $child_to_parent_rssi) {
				$min_rssi = $child_to_parent_rssi if $child_to_parent_rssi < $min_rssi;
				push @chain, "$current_serial($child_to_parent_rssi)";
			} else {
				warn "VISIBILITY: Node $current_serial has no meters.rssi for parent $parent_serial, ignoring";
			}

			$current_serial = $parent_serial;
		}

		$mesh_min_rssi{$ssid} = $min_rssi;
		warn "VISIBILITY: Full upstream chain for $node_serial: " . join(" -> ", @chain) .
		     ", weakest_rssi=$min_rssi";
	}

	# Step 4: pick AP per SSID with focused visibility logging
	my @result;
	for my $ssid (keys %aps_by_ssid) {

		my $entries = $aps_by_ssid{$ssid};
		next unless $entries && @$entries;

		if ($ssid =~ /^mesh-/) {

			my $seen = exists $aps_by_ssid{$ssid} ? 1 : 0;
			my $is_excluded = $exclude{$ssid} ? 1 : 0;
			my $min = defined $mesh_min_rssi{$ssid} ? $mesh_min_rssi{$ssid} : 'undef';

			if ($is_excluded) {
				warn "VISIBILITY: $ssid skipped (excluded child of $serial)";
				next;
			}

			unless ($seen) {
				warn "VISIBILITY: $ssid about to be included BUT NOT seen in wifi_scan for serial=$serial";
			}

			warn "VISIBILITY: INCLUDING $ssid for serial=$serial "
			   . "(seen=$seen, excluded=$is_excluded, upstream_min_rssi=$min)";

			my $base_entry = { %{ $entries->[0] } };
			$base_entry->{rssi} = $mesh_min_rssi{$ssid} if defined $mesh_min_rssi{$ssid};

			push @result, $base_entry;

		} else {
			# Regular AP: use most recent scan
			my ($latest_entry) = sort { $b->{unix_time} <=> $a->{unix_time} } @$entries;
			push @result, $latest_entry if $latest_entry;
		}
	}

	# Step 5: sort final results by RSSI descending
	@result = sort { $b->{rssi} <=> $a->{rssi} } @result;

	my $json = JSON::XS->new->utf8->canonical->encode(\@result);
	$r->print($json);

	return Apache2::Const::OK;
}

1;