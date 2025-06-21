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

# Tables to process
my @tables = qw(samples samples_cache);

# Fields to check for spikes
my @fields = qw(flow_temp return_flow_temp flow hours volume energy);

# Time threshold (in seconds)
my $time_threshold = 120;

# Spike factor for detection
my $spike_factor = 10;

# Minimum value threshold to avoid matching tiny noise
my $min_val_threshold = 1 / $spike_factor;

# Set number of parallel processes
my $pm = Parallel::ForkManager->new(scalar @tables);

foreach my $table (@tables) {
	$pm->start and next;

	my $dbh;
	if ($dbh = Nabovarme::Db->my_connect()) {
		$dbh->{mysql_auto_reconnect} = 1;
		print "[$table] connected to db\n";
	}
	else {
		print "[$table] can't connect to db $!\n";
		exit 1;
	}

	print "=== Processing table: $table ===\n";

	my $count_sth = $dbh->prepare("SELECT COUNT(*) FROM $table");
	$count_sth->execute();
	my ($row_count) = $count_sth->fetchrow_array;
	$count_sth->finish;

	if ($row_count == 0) {
		print "No data in $table — skipping\n\n";
		$dbh->disconnect;
		$pm->finish(0);
	}

	my $meter_sth = $dbh->prepare(qq[
		SELECT `serial` FROM meters
		WHERE enabled = 1 AND `serial` IS NOT NULL AND `serial` != ''
	]);
	$meter_sth->execute();

	my $select_samples_sth = $dbh->prepare(qq[
		SELECT id, unix_time, ] . join(",", @fields) . qq[
		FROM $table
		WHERE `serial` = ?
		AND is_spike != 1
		ORDER BY unix_time ASC
	]) or die "Failed to prepare select on $table: " . $dbh->errstr;

	my $mark_spike_sth = $dbh->prepare("UPDATE $table SET is_spike = 1 WHERE id = ?")
		or die "Failed to prepare update on $table: " . $dbh->errstr;

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
					($prev_val >= 1 || $val >= 1 || $next_val >= 1) && (

						# Flat spike: current is high, neighbors are zero
						($val > $spike_factor && $prev_val == 0 && $next_val == 0) ||

						# Flat dip: current is zero, neighbors are high
						($val == 0 && $prev_val > $spike_factor && $next_val > $spike_factor) ||

						# Surrounded by large values
						($val >= $min_val_threshold &&
						 $prev_val > $spike_factor * $val &&
						 $next_val > $spike_factor * $val) ||

						# Surrounded by small values
						($prev_val >= $min_val_threshold &&
						 $next_val >= $min_val_threshold &&
						 $val > $spike_factor * $prev_val &&
						 $val > $spike_factor * $next_val)
					)
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
	$pm->finish(0);
}

$pm->wait_all_children;
print "All done.\n";
