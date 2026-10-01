#!/usr/bin/perl -w

use strict;
use utf8;
use Data::Dumper;

use Nabovarme::Db;

binmode(STDOUT, ":utf8");
binmode(STDERR, ":utf8");

# Config
my $MAX_CHILDREN  = 5;

# Default lookback in days; override via first CLI argument (e.g., ./mesh_topology.pl 90)
my $default_lookback = 31;
my $LOOKBACK_DAYS    = ($ARGV[0] && $ARGV[0] =~ /^\d+$/) ? $ARGV[0] : $default_lookback;
print "Using lookback period: $LOOKBACK_DAYS days\n";

# Connect to DB
my $dbh = Nabovarme::Db->my_connect or die "DB connection failed";
$dbh->{'mysql_auto_reconnect'} = 1;

# Calculate time window
my ($latest_time) = $dbh->selectrow_array("SELECT MAX(unix_time) FROM wifi_scan");
$latest_time //= time(); # Fallback if table is empty
my $start_time = $latest_time - (3600 * 24 * $LOOKBACK_DAYS);

# Meters list (only enabled)
my $meters = $dbh->selectall_hashref("
	SELECT serial, info, ssid FROM meters WHERE enabled=1
", 'serial');

# Active external APs (roots)
my $active_aps = $dbh->selectcol_arrayref("
	SELECT DISTINCT ssid FROM meters
	WHERE enabled=1 AND ssid IS NOT NULL AND ssid NOT LIKE 'mesh-%'
");

my %allowed_aps = map { $_ => 1 } @$active_aps;

# Stream raw scans to calculate median RSSI in Perl (avoids slow MariaDB Window Functions)
my $sth = $dbh->prepare("
	SELECT ws.serial, ws.ssid, ws.rssi
	FROM wifi_scan ws
	JOIN meters m ON ws.serial = m.serial
	WHERE ws.unix_time BETWEEN ? AND ? AND m.enabled = 1
	  AND ws.rssi IS NOT NULL
");
$sth->execute($start_time, $latest_time);

my %scan_groups;
while (my $row = $sth->fetchrow_arrayref) {
	push @{ $scan_groups{$row->[0]}{$row->[1]} }, $row->[2];
}

# Build seen networks hash with median RSSI
my %seen_networks;
foreach my $serial (keys %scan_groups) {
	foreach my $ssid (keys %{ $scan_groups{$serial} }) {
		my @rssis = sort { $a <=> $b } @{ $scan_groups{$serial}{$ssid} };
		my $count = scalar(@rssis);
		
		my $mid = int($count / 2);
		my $median_rssi = ($count % 2)
			? $rssis[$mid]
			: int(($rssis[$mid-1] + $rssis[$mid]) / 2);
			
		my $score = $median_rssi + (2 * $count);
		push @{ $seen_networks{$serial} }, {
			ssid        => $ssid,
			median_rssi => $median_rssi,
			seen_count  => $count,
			score       => $score
		};
	}
}

# Parent-child structure & proposed link stats
my (%parent, %children, %link_stats);

# Cycle detection helper - prevents A->B->C->A deep cycles
sub creates_cycle {
	my ($node, $proposed_parent) = @_;
	my $curr = $proposed_parent;
	while (defined $curr) {
		return 1 if $curr eq $node;
		$curr = $parent{$curr};
	}
	return 0;
}

# Compute upstream chain stats (weakest RSSI along the PROPOSED path & total hop count)
sub get_proposed_chain_info {
	my ($node) = @_;
	my $stats = $link_stats{$node};
	return (0, 0) unless $stats;
	
	my $min_rssi = $stats->{median_rssi};
	my $hops     = 1;
	my $curr     = $node;
	my %seen;

	while (1) {
		last if $seen{$curr}++; # Prevent infinite loops
		
		my $p = $parent{$curr};
		last unless defined $p;
		last if $p =~ /^AP:/;
		
		if (defined $link_stats{$p}) {
			$min_rssi = $link_stats{$p}->{median_rssi} if $link_stats{$p}->{median_rssi} < $min_rssi;
			$hops++;
			$curr = $p;
		} else {
			last;
		}
	}
	return ($min_rssi, $hops);
}

# Build mesh links (Sorted iteration for deterministic topology building)
foreach my $esp (sort keys %$meters) {
	my $candidates = $seen_networks{$esp} || [];
	next unless @$candidates;

	# Sort by best score, fallback to ssid to resolve ties consistently
	my @sorted = sort { 
		$b->{score} <=> $a->{score} || 
		$a->{ssid} cmp $b->{ssid} 
	} @$candidates;

	my $chosen;
	for my $cand (@sorted) {
		if (exists $allowed_aps{$cand->{ssid}}) {
			# Connect directly to external AP
			$chosen = $cand;
			last;
		} elsif ($cand->{ssid} =~ /^mesh-(\d+)/) {
			my $target_serial = $1;
			
			# Strict validity checks
			next if $esp eq $target_serial;                           # no self-loop
			next unless exists $meters->{$target_serial};             # parent must be enabled
			next if creates_cycle($esp, $target_serial);              # prevent infinite loops
			next if scalar(@{ $children{$target_serial} || [] }) >= $MAX_CHILDREN; # capacity check
			
			$chosen = $cand;
			last;
		}
	}

	if ($chosen) {
		$link_stats{$esp} = $chosen;

		if (exists $allowed_aps{$chosen->{ssid}}) {
			$parent{$esp} = "AP:$chosen->{ssid}";
			print "meter $esp → external AP $chosen->{ssid} (score=$chosen->{score})\n";
		} elsif ($chosen->{ssid} =~ /^mesh-(\d+)/) {
			my $p = $1;
			$parent{$esp} = $p;
			push @{ $children{$p} }, $esp;
			print "meter $esp → mesh-$p (score=$chosen->{score})\n";
		}
	} else {
		print "DEBUG: meter $esp has no suitable parent (all candidates invalid/full)\n";
	}
}

# --- Print the mesh tree & Track Nodes ---
my %printed;
my @roots = sort grep { defined $parent{$_} && $parent{$_} =~ /^AP:/ } keys %parent;

sub print_tree {
	my ($node, $prefix) = @_;
	$printed{$node} = 1;
	
	my $info  = $meters->{$node}->{info} || '';
	my $label = $node;
	$label .= " ($info)" if $info ne '';

	if (my $stats = $link_stats{$node}) {
		my ($min_rssi, $hops) = get_proposed_chain_info($node);
		if ($stats->{ssid} =~ /^mesh-/) {
			$label .= sprintf(" [local_rssi=%d, min_chain_rssi=%d, hops=%d]", $stats->{median_rssi}, $min_rssi, $hops);
		} else {
			$label .= sprintf(" [rssi=%d, hops=1]", $stats->{median_rssi});
		}
	}

	if ($parent{$node} && $parent{$node} =~ /^AP:(.+)/) {
		$label .= " [ROOT via AP: $1]";
	}
	
	print $prefix, $label, "\n";

	if (exists $children{$node}) {
		foreach my $child (sort @{ $children{$node} }) {
			print_tree($child, $prefix . "  ");
		}
	}
}

print "\n--- Suggested Mesh Topology ---\n";
foreach my $root (@roots) {
	print_tree($root, "");
}

# --- Print isolated ---
my @isolated = sort grep { ! $printed{$_} } keys %$meters;
if (@isolated) {
	print "\n--- Isolated Meters (no connection) ---\n";
	foreach my $m (@isolated) {
		my $info = $meters->{$m}->{info} || '';
		print "$m ($info)\n";
	}
}

$dbh->disconnect;
