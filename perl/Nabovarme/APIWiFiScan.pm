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

		next unless defined $first_entry_ref && defined $first_entry_ref->{rssi};

		my $min_rssi = $first_entry_ref->{rssi};
		my @chain = ("$node_serial($min_rssi)");

		my $current_serial = $node_serial;

		while (1) {

			# Get the SSID this node is connected to (actual SSID, not forced mesh-)
			my ($parent_ssid) = $dbh->selectrow_array(
				"SELECT ssid FROM meters WHERE serial = ?",
				undef, $current_serial
			);

			last unless defined $parent_ssid && $parent_ssid ne '';

			# Get RSSI for this connection from meters
			my ($child_to_parent_rssi) = $dbh->selectrow_array(
				"SELECT rssi FROM meters WHERE serial = ? AND ssid = ?",
				undef, $current_serial, $parent_ssid
			);

			if (defined $child_to_parent_rssi) {
				$min_rssi = $child_to_parent_rssi if $child_to_parent_rssi < $min_rssi;
				push @chain, "$current_serial($child_to_parent_rssi)";
			}

			# If parent SSID is mesh-<serial>, continue upstream
			if ($parent_ssid =~ /^mesh-(.*)$/) {
				$current_serial = $1;
			} else {
				# Reached root AP (non-mesh SSID like Gustav)
				last;
			}
		}

		$mesh_min_rssi{$ssid} = $min_rssi;
	}

	# Step 4: pick AP per SSID, skipping SSID currently connected to
	my ($current_connected_ssid) = $dbh->selectrow_array(
		"SELECT ssid FROM meters WHERE serial = ?", undef, $serial
	);

	my @result;
	for my $ssid (keys %aps_by_ssid) {

		my $entries = $aps_by_ssid{$ssid};
		next unless $entries && @$entries;

		# Skip the SSID the serial is currently connected to
		next if defined $current_connected_ssid && $ssid eq $current_connected_ssid;

		if ($ssid =~ /^mesh-/) {

			my $is_excluded = $exclude{$ssid} ? 1 : 0;
			next if $is_excluded;

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