#!/usr/bin/perl -w

use strict;
use utf8;
use Data::Dumper;

use lib qw( MeterLogger/perl );
use Nabovarme::Db;

binmode(STDOUT, ":utf8");
binmode(STDERR, ":utf8");

# --- Config ---
my $LOOKBACK_DAYS = 31;  # Look back in wifi_scan
my $ROOT_SERIAL   = shift @ARGV or die "Usage: $0 <root_serial>\n";

# --- Connect to DB ---
my $dbh;
if ($dbh = Nabovarme::Db->my_connect) {
	$dbh->{'mysql_auto_reconnect'} = 1;
} else {
	die "Unable to connect to database\n";
}

# --- Calculate time window ---
my ($latest_time) = $dbh->selectrow_array("SELECT MAX(unix_time) FROM wifi_scan");
my $start_time	= $latest_time - (3600 * 24 * $LOOKBACK_DAYS);

# --- Load meters ---
my $meters = $dbh->selectall_hashref("
	SELECT serial, ssid, enabled FROM meters
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

# --- Recursive tree walker ---
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

print "--- Mesh Tree starting from $ROOT_SERIAL ---\n";
sub print_tree {
	my ($node, $prefix) = @_;
	print $prefix, $node, "\n";
	if (exists $children{$node}) {
		foreach my $c (@{ $children{$node} }) {
			print_tree($c, $prefix . "  ");
		}
	}
}
print_tree($ROOT_SERIAL, "");

# --- Get average RSSI for ROOT serial ---
my $avg_rssi_data = $dbh->selectall_arrayref("
	SELECT ssid, AVG(rssi) AS avg_rssi, COUNT(*) AS seen_count
	FROM wifi_scan
	WHERE serial = ? AND unix_time BETWEEN ? AND ?
	GROUP BY ssid
", { Slice => {} }, $ROOT_SERIAL, $start_time, $latest_time);

# --- Filter out any SSID that points to removed meters ---
my @candidates;
foreach my $row (@$avg_rssi_data) {
	my $ssid = $row->{ssid} // next;
	if ($ssid =~ /^mesh-(\w+)/) {
		my $target_serial = $1;
		next if exists $tree_members{$target_serial};  # skip self/children
		push @candidates, {
			type	  => "mesh",
			target	=> $target_serial,
			avg_rssi  => $row->{avg_rssi},
			seen_count=> $row->{seen_count}
		};
	} else {
		# External AP
		push @candidates, {
			type	  => "ap",
			target	=> $ssid,
			avg_rssi  => $row->{avg_rssi},
			seen_count=> $row->{seen_count}
		};
	}
}

# --- Sort by avg_rssi descending ---
@candidates = sort { $b->{avg_rssi} <=> $a->{avg_rssi} } @candidates;

print "\n--- Possible Connections for $ROOT_SERIAL ---\n";
foreach my $cand (@candidates) {
	if ($cand->{type} eq 'mesh') {
		print "mesh-$cand->{target}  RSSI=$cand->{avg_rssi}  seen=$cand->{seen_count}\n";
	} else {
		print "AP:$cand->{target}   RSSI=$cand->{avg_rssi}  seen=$cand->{seen_count}\n";
	}
}

$dbh->disconnect;
