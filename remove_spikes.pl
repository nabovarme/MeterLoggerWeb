#!/usr/bin/perl -w

use strict;
use warnings;
use Data::Dumper;
use DBI;
use Config;
use Parallel::ForkManager;

# Include custom library path
use lib qw( /etc/apache2/perl );
use Nabovarme::Db;

$| = 1;  # Autoflush STDOUT

# Tables to process in the same database
my @tables = qw(samples_cache samples_daily samples_hourly);

# Fields to check for spikes
my @fields = qw(flow_temp return_flow_temp temp_diff flow effect hours volume energy);

# Time thresholds per table (in seconds)
my %time_thresholds = (
	samples_cache  => 120,		# 2 minutes
	samples_hourly => 3600,		# 1 hour
	samples_daily  => 86400,	# 1 day
);

# Set max parallel processes (e.g., 3 or 4 depending on your CPU)
my $max_processes = 3;
my $pm = Parallel::ForkManager->new($max_processes);

foreach my $table (@tables) {
	$pm->start and next;  # Fork child, parent goes to next iteration

	# Child process code begins

	# Connect to the database inside the child
	my $dbh;
	if ($dbh = Nabovarme::Db->my_connect()) {
		$dbh->{mysql_auto_reconnect} = 1;
		print "[$table] connected to db\n";
	} else {
		print "[$table] can't connect to db $!\n";
		exit 1;  # Exit child with error
	}

	print "=== Processing table: $table ===\n";

	# Use per-table time threshold, fallback to 120 seconds
	my $time_threshold = $time_thresholds{$table} || 120;

	# Check if table has any samples
	my $count_sth = $dbh->prepare("SELECT COUNT(*) FROM $table");
	$count_sth->execute();
	my ($row_count) = $count_sth->fetchrow_array;
	$count_sth->finish;

	if ($row_count == 0) {
		print "No data in $table — skipping\n\n";
		$dbh->disconnect;
		$pm->finish(0);
	}

	# Prepare and execute meters query
	my $meter_sth = $dbh->prepare(qq[
		SELECT `serial` FROM meters
		WHERE enabled = 1 AND `serial` IS NOT NULL AND `serial` != ''
	]);
	$meter_sth->execute();

	# Prepare SELECT and DELETE statements
	my $select_samples_sth = $dbh->prepare(qq[
		SELECT id, unix_time, ] . join(",", @fields) . qq[
		FROM $table
		WHERE `serial` = ?
		ORDER BY unix_time ASC
	]) or die "Failed to prepare select on $table: " . $dbh->errstr;

	my $delete_sample_sth = $dbh->prepare("DELETE FROM $table WHERE id = ?")
		or die "Failed to prepare delete on $table: " . $dbh->errstr;

	# Process each meter
	while (my ($serial) = $meter_sth->fetchrow_array) {
		print "[$table] Processing serial: $serial\n";

		$select_samples_sth->execute($serial)
			or die "Failed to execute select on $table for serial $serial: " . $select_samples_sth->errstr;

		my ($prev, $curr);
		if ($select_samples_sth->rows >= 2) {
			# Fetch first two rows to check for enough data
			$prev = $select_samples_sth->fetchrow_hashref;
			$curr = $select_samples_sth->fetchrow_hashref;
		}
		else {
			print "Not enough samples for serial $serial in table $table — skipping\n";
			next;
		}

		my $count_deleted = 0;

		# Walk through the rest of the samples
		while (my $next = $select_samples_sth->fetchrow_hashref) {
			my $delete = 0;

			# Check time spacing
			my $prev_diff = abs($curr->{unix_time} - $prev->{unix_time});
			my $next_diff = abs($next->{unix_time} - $curr->{unix_time});

			# Skip if not within time threshold
			if ($prev_diff > $time_threshold || $next_diff > $time_threshold) {
				$prev = $curr;
				$curr = $next;
				next;
			}

			foreach my $field (@fields) {
				my ($val, $prev_val, $next_val) = ($curr->{$field}, $prev->{$field}, $next->{$field});
				next unless defined $val && defined $prev_val && defined $next_val;
				next if $prev_val == 0 || $next_val == 0;

				if (($val > 10 * $prev_val && $val > 10 * $next_val) ||
					($val < 0.1 * $prev_val && $val < 0.1 * $next_val)) {
					$delete = 1;
					print "[$table] Deleted spike at $curr->{unix_time} on $field (value = $val)\n";
					last;
				}
			}

			if ($delete) {
				$delete_sample_sth->execute($curr->{id});
				$count_deleted++;
			}

			$prev = $curr;
			$curr = $next;
		}

		print "[$table] Done serial: $serial — Deleted $count_deleted samples\n\n";
	}

	$select_samples_sth->finish;
	$delete_sample_sth->finish;
	$meter_sth->finish;

	print "=== Finished processing table: $table ===\n\n";

	$dbh->disconnect;
	$pm->finish(0);  # Child exits here
}

$pm->wait_all_children;

print "All tables processed.\n";
