#!/usr/bin/perl -w

use strict;
use utf8;
use Data::Dumper;

use lib qw( MeterLogger/perl );
use Nabovarme::Db;

binmode(STDOUT, ":utf8");
binmode(STDERR, ":utf8");

# Config
my $MAX_CHILDREN  = 5;
my $LOOKBACK_DAYS = 31;   # Look back 7 days (was 100)

# Connect to DB
my $dbh;
if ($dbh = Nabovarme::Db->my_connect) {
	$dbh->{'mysql_auto_reconnect'} = 1;
}

# Calculate time window
my ($latest_time) = $dbh->selectrow_array("SELECT MAX(unix_time) FROM wifi_scan");
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

# Aggregate last 7 days scans
my $scans = $dbh->selectall_arrayref("
	SELECT serial, ssid, AVG(rssi) as avg_rssi, COUNT(*) as seen_count
	FROM wifi_scan
	WHERE unix_time BETWEEN ? AND ?
	GROUP BY serial, ssid
", { Slice => {} }, $start_time, $latest_time);

# Build seen networks hash
my %seen_networks;
foreach my $row (@$scans) {
	my $score = $row->{avg_rssi} + (2 * $row->{seen_count});
	push @{ $seen_networks{$row->{serial}} }, {
		ssid	   => $row->{ssid},
		avg_rssi   => $row->{avg_rssi},
		seen_count => $row->{seen_count},
		score	  => $score
	};
}

# Parent-child structure
my (%parent, %children);

# Build mesh links
foreach my $esp (keys %$meters) {
	my $candidates = $seen_networks{$esp} || [];
	next unless @$candidates;

	# Sort by best score (RSSI + stability)
	my @sorted = sort { $b->{score} <=> $a->{score} } @$candidates;

	my $chosen;
	for my $cand (@sorted) {
		if (exists $allowed_aps{$cand->{ssid}}) {
			# Connect directly to external AP
			$chosen = $cand;
			last;
		} elsif ($cand->{ssid} =~ /^mesh-(\d+)/) {
			my ($target_serial) = $cand->{ssid} =~ /^mesh-(\d+)/;
			# Check mesh parent is valid
			next if $esp eq $target_serial;						   # no self-loop
			next unless exists $meters->{$target_serial};			# parent must be enabled
			next if exists $parent{$target_serial} 
				&& $parent{$target_serial} eq $esp;				  # avoid cycles
			next if scalar(@{ $children{$target_serial} || [] }) >= $MAX_CHILDREN;
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
		print "DEBUG: meter $esp has no suitable parent (all candidates invalid)\n";
	}
}

# --- Print the mesh tree ---
my @roots = grep { defined $parent{$_} && $parent{$_} =~ /^AP:/ } keys %parent;

sub print_tree {
	my ($node, $prefix) = @_;
	my $info  = $meters->{$node}->{info} // '';
	my $label = $node;
	$label .= " ($info)" if $info ne '';
	if ($parent{$node} && $parent{$node} =~ /^AP:(.+)/) {
		$label .= " [ROOT via AP: $1]";
	}
	print $prefix, $label, "\n";

	if (exists $children{$node}) {
		foreach my $child (@{ $children{$node} }) {
			print_tree($child, $prefix . "  ");
		}
	}
}

print "\n--- Suggested Mesh Topology ---\n";
foreach my $root (@roots) {
	print_tree($root, "");
}

# --- Track printed nodes properly ---
my %printed;
sub mark_printed {
	my ($node) = @_;
	$printed{$node} = 1;
	if (exists $children{$node}) {
		mark_printed($_) for @{ $children{$node} };
	}
}
mark_printed($_) for @roots;

# --- Print isolated (not printed anywhere) ---
my @isolated = grep { ! $printed{$_} } keys %$meters;
if (@isolated) {
	print "\n--- Isolated Meters (no connection) ---\n";
	foreach my $m (@isolated) {
		my $info = $meters->{$m}->{info} // '';
		print "$m ($info)\n";
	}
}

$dbh->disconnect;
