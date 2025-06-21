#!/usr/bin/perl -w

use strict;
use warnings;
use Data::Dumper;
use DBI;
use Config;

# Include custom library path
use lib qw( /etc/apache2/perl );
use Nabovarme::Db;

$| = 1;  # Autoflush STDOUT

# Only process this one table
my $table = 'samples';

# Fields to check for spikes
my @fields = qw(flow_temp return_flow_temp temp_diff flow effect hours volume energy);

# Time threshold (in seconds) for this table
my $time_threshold = 120;

# Connect to the database
my $dbh;
if ($dbh = Nabovarme::Db->my_connect()) {
	$dbh->{mysql_auto_reconnect} = 1;
	print "[$table] connected to db\n";
} else {
	print "[$table] can't connect to db $!\n";
	exit 1;
}

print "=== Processing table: $table ===\n";

# Check if table has any samples
my $count_sth = $dbh->prepare("SELECT COUNT(*) FROM $table");
$count_sth->execute();
my ($row_count) = $count_sth->fetchrow_array;
$count_sth->finish;

if ($row_count == 0) {
	print "No data in $table — skipping\n\n";
	$dbh->disconnect;
	exit 0;
}

# Prepare and execute meters query
my $meter_sth = $dbh->prepare(qq[
	SELECT `serial` FROM meters
	WHERE enabled = 1 AND `serial` IS NOT NULL AND `serial` != ''
]);
$meter_sth->execute();

# Prepare SELECT and UPDATE statements
my $select_samples_sth = $dbh->prepare(qq[
	SELECT id, unix_time, ] . join(",", @fields) . qq[
	FROM $table
	WHERE `serial` = ?
	ORDER BY unix_time ASC
]) or die "Failed to prepare select on $table: " . $dbh->errstr;

my $mark_spike_sth = $dbh->prepare("UPDATE $table SET is_spike = 1 WHERE id = ?")
	or die "Failed to prepare update on $table: " . $dbh->errstr;

# Process each meter
my $total_marked = 0;

while (my ($serial) = $meter_sth->fetchrow_array) {
	print "[$table] Processing serial: $serial\n";

	$select_samples_sth->execute($serial)
		or die "Failed to execute select on $table for serial $serial: " . $select_samples_sth->errstr;

	my ($prev, $curr);
	if ($select_samples_sth->rows >= 2) {
		$prev = $select_samples_sth->fetchrow_hashref;
		$curr = $select_samples_sth->fetchrow_hashref;
	} else {
		print "Not enough samples for serial $serial in table $table — skipping\n";
		next;
	}

	my $count_marked = 0;

	while (my $next = $select_samples_sth->fetchrow_hashref) {
		my $mark = 0;

		my $prev_diff = abs($curr->{unix_time} - $prev->{unix_time});
		my $next_diff = abs($next->{unix_time} - $curr->{unix_time});

		if ($prev_diff > $time_threshold || $next_diff > $time_threshold) {
			$prev = $curr;
			$curr = $next;
			next;
		}

		foreach my $field (@fields) {
			my ($val, $prev_val, $next_val) = ($curr->{$field}, $prev->{$field}, $next->{$field});
			next unless defined $val && defined $prev_val && defined $next_val;

			if (
				($val > 10 * $prev_val && $val > 10 * $next_val) ||
				($val < 0.1 * $prev_val && $val < 0.1 * $next_val) ||
				($val > 10 && $prev_val == 0 && $next_val == 0)
			) {
				$mark = 1;
				print "[$table] Marked spike at $curr->{unix_time} on $field:\n";
				print "		 prev=$prev_val, curr=$val, next=$next_val\n";
				last;
			}
		}

		if ($mark) {
			$mark_spike_sth->execute($curr->{id});
			$count_marked++;
		}

		$prev = $curr;
		$curr = $next;
	}

	print "[$table] Done serial: $serial — Marked $count_marked samples as spike\n\n";
	$total_marked += $count_marked;
}

$select_samples_sth->finish;
$mark_spike_sth->finish;
$meter_sth->finish;

print "=== Finished processing table: $table ===\n";
print "Total marked as spike: $total_marked\n\n";

$dbh->disconnect;

print "All done.\n";
