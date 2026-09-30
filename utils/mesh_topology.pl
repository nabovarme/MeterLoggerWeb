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
	SELECT serial, info, ssid, rssi FROM meters WHERE enabled=1
", 'serial');

# Active external APs (roots)
my $active_aps = $dbh->selectcol_arrayref("
	SELECT DISTINCT ssid FROM meters
	WHERE enabled=1 AND ssid IS NOT NULL AND ssid NOT LIKE 'mesh-%'
");

my %allowed_aps = map { $_ => 1 } @$active_aps;

# Aggregate last N days scans
my $scans = $dbh->selectall_arrayref("
	SELECT ws.serial, ws.ssid, AVG(ws.rssi) as avg_rssi, COUNT(*) as seen_count
	FROM wifi_scan ws
	JOIN meters m ON ws.serial = m.serial
	WHERE ws.unix_time BETWEEN ? AND ? AND m.enabled = 1
	GROUP BY ws.serial, ws.ssid
", { Slice => {} }, $start_time, $latest_time);

# Build seen networks hash
my %seen_networks;
foreach my $row (@$scans) {
	my $score = $row->{avg_rssi} + (2 * $row->{seen_count});
	push @{ $seen_networks{$row->{serial}} }, {
		ssid       => $row->{ssid},
		avg_rssi   => int($row->{avg_rssi}),
		seen_count => $row->{seen_count},
		score      => $score
	};
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

# Helper matching APIWiFiScan: Walk the LIVE network to find upstream bottleneck
sub get_live_chain_info {
	my ($node_serial, $direct_rssi) = @_;
	
	my $min_rssi = $direct_rssi;
	my $hops     = 1;
	my $curr     = $node_serial;
	my %seen_live;

	while (1) {
		last if $seen_live{$curr}++; # Prevent infinite loop if live DB has a cycle
		
		my $m = $meters->{$curr};
		last unless $m && defined $m->{ssid} && $m->{ssid} ne '';
		
		if (defined $m->{rssi} && $m->{rssi} < $min_rssi) {
			$min_rssi = $m->{rssi};
		}
		
		if ($m->{ssid} =~ /^mesh-(.*)$/) {
			$curr = $1;
			$hops++;
		} else {
			last; # Reached external AP
		}
	}
	return ($min_rssi, $hops);
}

# Build mesh links (Sorted iteration for deterministic topology building)
foreach my $esp (sort keys %$meters) {
	my $candidates = $seen_networks{$esp} || [];
	next unless @$candidates;

	# Calculate upstream bottleneck for each candidate to adjust its effective score
	foreach my $cand (@$candidates) {
		if ($cand->{ssid} =~ /^mesh-(\d+)/) {
			my $target_serial = $1;
			my ($min_rssi, $hops) = get_live_chain_info($target_serial, $cand->{avg_rssi});
			$cand->{eff_rssi}  = $min_rssi;
			$cand->{hops}      = $hops;
			$cand->{eff_score} = $min_rssi + (2 * $cand->{seen_count});
		} else {
			$cand->{eff_rssi}  = $cand->{avg_rssi};
			$cand->{hops}      = 1;
			$cand->{eff_score} = $cand->{score};
		}
	}

	# Sort candidates using the bottleneck-adjusted effective score
	my @sorted = sort { 
		$b->{eff_score} <=> $a->{eff_score} || 
		$a->{ssid} cmp $b->{ssid} 
	} @$candidates;

	my $chosen;
	for my $cand (@sorted) {
		if (exists $allowed_aps{$cand->{ssid}}) {
			$chosen = $cand;
			last;
		} elsif ($cand->{ssid} =~ /^mesh-(\d+)/) {
			my $target_serial = $1;
			
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
			print "meter $esp → external AP $chosen->{ssid} (rssi=$chosen->{eff_rssi} dBm, score=$chosen->{eff_score})\n";
		} elsif ($chosen->{ssid} =~ /^mesh-(\d+)/) {
			my $p = $1;
			$parent{$esp} = $p;
			push @{ $children{$p} }, $esp;
			print "meter $esp → mesh-$p (local_rssi=$chosen->{avg_rssi} dBm, min_chain_rssi=$chosen->{eff_rssi} dBm, hops=$chosen->{hops}, score=$chosen->{eff_score})\n";
		}
	} else {
		print "DEBUG: meter $esp has no suitable parent\n";
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
		if ($stats->{ssid} =~ /^mesh-/) {
			$label .= sprintf(" [local_rssi=%d, min_chain_rssi=%d, hops=%d]", $stats->{avg_rssi}, $stats->{eff_rssi}, $stats->{hops});
		} else {
			$label .= sprintf(" [rssi=%d, hops=1]", $stats->{eff_rssi});
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
