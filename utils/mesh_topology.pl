#!/usr/bin/perl -w

use strict;
use utf8;
use Data::Dumper;

use Nabovarme::Db;

binmode(STDOUT, ":utf8");
binmode(STDERR, ":utf8");

# Config
my $MAX_CHILDREN  = 5;
my $LOOKBACK_DAYS = 31;   # Look back 31 days

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

# Aggregate last N days scans - OPTIMIZED: Joined with meters to filter out disabled devices early
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
		avg_rssi   => $row->{avg_rssi},
		seen_count => $row->{seen_count},
		score      => $score
	};
}

# Parent-child structure
my (%parent, %children);

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
