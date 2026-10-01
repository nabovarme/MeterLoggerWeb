#!/usr/bin/perl -w

use strict;
use utf8;
use Data::Dumper;

use Nabovarme::Db;

binmode(STDOUT, ":utf8");
binmode(STDERR, ":utf8");

# --- Config & CLI Arguments ---
my $ROOT_SERIAL = shift @ARGV or die "Usage: $0 <root_serial> [lookback_days]\n";

my $default_lookback = 31;
my $LOOKBACK_DAYS    = ($ARGV[0] && $ARGV[0] =~ /^\d+$/) ? $ARGV[0] : $default_lookback;
print "Using lookback period: $LOOKBACK_DAYS days\n";

# --- Connect to DB ---
my $dbh;
if ($dbh = Nabovarme::Db->my_connect) {
	$dbh->{'mysql_auto_reconnect'} = 1;
} else {
	die "Unable to connect to database\n";
}

# --- Calculate time window ---
my ($latest_time) = $dbh->selectrow_array("SELECT MAX(unix_time) FROM wifi_scan");
$latest_time //= time();
my $start_time	= $latest_time - (3600 * 24 * $LOOKBACK_DAYS);

# --- Load meters (now including 'info') ---
my $meters = $dbh->selectall_hashref("
	SELECT serial, info, ssid, rssi, enabled, ping_average_packet_loss
	FROM meters
", 'serial');

# --- Build parent->child mapping ---
my %children;
my $mesh_links = $dbh->selectall_arrayref("
	SELECT m1.serial AS child_serial, m2.serial AS parent_serial
	FROM meters m1
	JOIN meters m2 ON m1.ssid = CONCAT('mesh-', m2.serial)
	WHERE m1.enabled=1 AND m2.enabled=1
", { Slice => {} });

foreach my $row (@$mesh_links) {
	push @{ $children{$row->{parent_serial}} }, $row->{child_serial};
}

# --- Recursive tree walker (find subtree under $ROOT_SERIAL) ---
my %tree_members;
sub walk_tree {
	my ($serial) = @_;
	$tree_members{$serial} = 1;
	if (exists $children{$serial}) {
		foreach my $c (@{ $children{$serial} }) {
			walk_tree($c);
		}
	}
}

walk_tree($ROOT_SERIAL);

my $root_info = $meters->{$ROOT_SERIAL}->{info} || '';
my $root_label = $ROOT_SERIAL;
$root_label .= " ($root_info)" if $root_info ne '';

print "--- Mesh Tree starting from $root_label ---\n";
sub print_tree {
	my ($node, $prefix) = @_;
	
	my $info = $meters->{$node}->{info} || '';
	my $label = $node;
	$label .= " ($info)" if $info ne '';
	
	print $prefix, $label, "\n";
	
	if (exists $children{$node}) {
		foreach my $c (@{ $children{$node} }) {
			print_tree($c, $prefix . "  ");
		}
	}
}
print_tree($ROOT_SERIAL, "");

# --- Stream wifi_scan data for ROOT_SERIAL and compute Median RSSI ---
my $sth_scans = $dbh->prepare("
	SELECT ssid, rssi
	FROM wifi_scan
	WHERE serial = ? AND unix_time BETWEEN ? AND ?
	  AND rssi IS NOT NULL
");
$sth_scans->execute($ROOT_SERIAL, $start_time, $latest_time);

my %scan_groups;
while (my ($ssid, $rssi) = $sth_scans->fetchrow_array) {
	push @{ $scan_groups{$ssid} }, $rssi;
}

# --- Helper: Walk LIVE network to calculate upstream chain bottleneck ---
sub get_live_chain_info {
	my ($node_serial, $direct_rssi) = @_;
	
	my $min_rssi = $direct_rssi;
	my $hops     = 1;
	my $curr     = $node_serial;
	my %seen_live;

	while (1) {
		last if $seen_live{$curr}++; # Prevent infinite loops
		
		my $m = $meters->{$curr};
		last unless $m && defined $m->{ssid} && $m->{ssid} ne '';
		
		if (defined $m->{rssi} && $m->{rssi} ne '' && $m->{rssi} < $min_rssi) {
			$min_rssi = $m->{rssi};
		}
		
		if ($m->{ssid} =~ /^mesh-(.*)$/) {
			$curr = $1;
			$hops++;
		} else {
			last; # Reached external root AP
		}
	}
	return ($min_rssi, $hops);
}

# --- Build candidate list ---
my @candidates;
foreach my $ssid (keys %scan_groups) {
	my @rssi_vals = sort { $a <=> $b } @{ $scan_groups{$ssid} };
	my $seen_count = scalar(@rssi_vals);
	next unless $seen_count;

	my $mid = int($seen_count / 2);
	my $median_rssi = ($seen_count % 2)
		? $rssi_vals[$mid]
		: int(($rssi_vals[$mid-1] + $rssi_vals[$mid]) / 2);

	my $score = $median_rssi + (2 * $seen_count);

	if ($ssid =~ /^mesh-(\w+)/) {
		my $target_serial = $1;
		next if exists $tree_members{$target_serial};  # skip self and downstream children

		my ($min_chain_rssi, $hops) = get_live_chain_info($target_serial, $median_rssi);

		# Penalize score by packet loss if available
		if (defined $meters->{$target_serial}->{ping_average_packet_loss} 
			&& $meters->{$target_serial}->{ping_average_packet_loss} =~ /^([\d.]+)%$/) {
			my $loss = $1;
			$score -= $loss;
		}

		push @candidates, {
			type           => "mesh",
			target         => $target_serial,
			median_rssi    => $median_rssi,
			min_chain_rssi => $min_chain_rssi,
			hops           => $hops,
			seen_count     => $seen_count,
			score          => $score
		};
	} else {
		# External AP
		push @candidates, {
			type        => "ap",
			target      => $ssid,
			median_rssi => $median_rssi,
			hops        => 1,
			seen_count  => $seen_count,
			score       => $score
		};
	}
}

# --- Sort by score descending ---
@candidates = sort { $b->{score} <=> $a->{score} } @candidates;

print "\n--- Possible Connections for $root_label ---\n";
foreach my $cand (@candidates) {
	my $loss_str = '';
	if ($cand->{type} eq 'mesh' 
		&& defined $meters->{$cand->{target}}->{ping_average_packet_loss}) {
		$loss_str = " loss=" . $meters->{$cand->{target}}->{ping_average_packet_loss};
	}

	if ($cand->{type} eq 'mesh') {
		my $info = $meters->{$cand->{target}}->{info} || '';
		my $target_label = $cand->{target};
		$target_label .= " ($info)" if $info ne '';

		printf("mesh-%-30s local_rssi=%-4d min_chain_rssi=%-4d hops=%-2d seen=%-4d score=%-6.1f%s\n",
			$target_label, $cand->{median_rssi}, $cand->{min_chain_rssi}, $cand->{hops}, $cand->{seen_count}, $cand->{score}, $loss_str);
	} else {
		printf("AP:%-32s rssi=%-10d hops=1  seen=%-4d score=%-6.1f\n",
			$cand->{target}, $cand->{median_rssi}, $cand->{seen_count}, $cand->{score});
	}
}

$dbh->disconnect;
