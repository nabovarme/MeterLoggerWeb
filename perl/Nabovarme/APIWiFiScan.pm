package Nabovarme::APIWiFiScan;

use strict;
use warnings;
use utf8;
use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::Const -compile => qw(OK HTTP_BAD_REQUEST HTTP_SERVICE_UNAVAILABLE);
use HTTP::Date;
use JSON ();

use Nabovarme::Db;

# Helper to compute integer median RSSI from scan entries
sub _calc_median_rssi {
	my ($entries) = @_;
	my @rssi_vals = map { $_->{rssi} }
		grep { defined $_->{rssi} && $_->{rssi} ne '' } @$entries;

	return undef unless @rssi_vals;

	@rssi_vals = sort { $a <=> $b } @rssi_vals;
	my $mid = int(@rssi_vals / 2);

	return (@rssi_vals % 2)
		? $rssi_vals[$mid]
		: int(($rssi_vals[$mid - 1] + $rssi_vals[$mid]) / 2);
}

sub handler {
	my $r = shift;

	my $orig_uri = $r->unparsed_uri || $r->uri;
	my ($serial) = $orig_uri =~ m{/([A-Za-z0-9_-]{1,16})$};
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

	# Step 3: compute upstream weakest median RSSI along the mesh chain
	my %mesh_chain_info;

	for my $ssid (keys %aps_by_ssid) {
		next unless $ssid =~ /^mesh-/;

		my ($node_serial) = $ssid =~ /^mesh-(.*)$/;

		# Compute median RSSI for this local mesh AP link
		my $local_median_rssi = _calc_median_rssi($aps_by_ssid{$ssid});
		next unless defined $local_median_rssi;

		my $min_rssi = $local_median_rssi;
		my $hop_count = 1;
		my $current_serial = $node_serial;

		while (1) {
			# Get the SSID and RSSI this node is connected to
			my ($parent_ssid, $child_to_parent_rssi) = $dbh->selectrow_array(
				"SELECT ssid, rssi FROM meters WHERE serial = ?",
				undef, $current_serial
			);

			last unless defined $parent_ssid && $parent_ssid ne '';

			if (defined $child_to_parent_rssi && $child_to_parent_rssi ne '') {
				$min_rssi = $child_to_parent_rssi if $child_to_parent_rssi < $min_rssi;
			}

			# If parent SSID is mesh-<serial>, continue upstream
			if ($parent_ssid =~ /^mesh-(.*)$/) {
				$current_serial = $1;
				$hop_count++;
			} else {
				# Reached root AP
				last;
			}
		}

		$mesh_chain_info{$ssid} = {
			min_rssi    => $min_rssi,
			median_rssi => $local_median_rssi,
			hop         => $hop_count,
		};
	}

	# Step 4: pick AP per SSID, applying median RSSI to all APs
	my ($current_connected_ssid) = $dbh->selectrow_array(
		"SELECT ssid FROM meters WHERE serial = ?", undef, $serial
	);

	my @result;
	for my $ssid (keys %aps_by_ssid) {

		# Filter out unwanted network SSIDs from Wi-Fi scan results
		next if $ssid =~ /^(?:KAM_|stofferFon)/i;

		my $entries = $aps_by_ssid{$ssid};
		next unless $entries && @$entries;

		# Base record taken from the most recent scan entry for metadata (channel, ciphers, etc.)
		my ($latest_entry) = sort { $b->{unix_time} <=> $a->{unix_time} } @$entries;
		my $base_entry = { %$latest_entry };

		# Flag the currently connected network for the UI
		$base_entry->{connected} = (defined $current_connected_ssid && $ssid eq $current_connected_ssid) ? 1 : 0;

		if ($ssid =~ /^mesh-/) {

			my $is_excluded = $exclude{$ssid} ? 1 : 0;
			next if $is_excluded;

			if (my $info = $mesh_chain_info{$ssid}) {
				$base_entry->{rssi} = $info->{min_rssi};
				$base_entry->{hop}  = $info->{hop};
				
				my ($mesh_serial) = $ssid =~ /^mesh-(.*)$/;
				my ($meter_info)  = $dbh->selectrow_array("SELECT info FROM meters WHERE serial = ?", undef, $mesh_serial);
				
				if (defined $meter_info && $meter_info ne '') {
					$base_entry->{info} = $meter_info;
				}

				push @result, $base_entry;
			}

		} else {
			# Regular AP: compute median RSSI across all scans for this SSID
			my $median_rssi = _calc_median_rssi($entries);
			if (defined $median_rssi) {
				$base_entry->{rssi} = $median_rssi;
				push @result, $base_entry;
			}
		}
	}

	# Step 5: sort final results by RSSI descending
	@result = sort { $b->{rssi} <=> $a->{rssi} } @result;

	$r->print(
		JSON->new->utf8->canonical->encode(\@result)
	);

	return Apache2::Const::OK;
}

1;
