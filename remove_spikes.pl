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

# === CONFIGURATION ===

# Tables to process
my @tables = qw(samples samples_cache);

# Fields to check for spikes
my @fields = qw(flow_temp return_flow_temp flow hours volume energy);

# Time threshold (in seconds) to consider data as continuous
my $time_threshold = 120;

# Spike detection sensitivity
my $spike_factor = 10;

# Minimum value to avoid flagging noise as spike
my $min_val_threshold = 1 / $spike_factor;

# Max parallel child processes (tune for your system)
my $max_processes = 8;

# === PARALLEL SETUP ===

my $pm = Parallel::ForkManager->new($max_processes);

foreach my $table (@tables) {
	print "\n=== Preparing table: $table ===\n";

	my $dbh = Nabovarme::Db->my_connect() or die "[$table] Cannot connect to DB";
	$dbh->{mysql_auto_reconnect} = 1;

	my $meter_sth = $dbh->prepare(qq[
		SELECT `serial` FROM meters
		WHERE enabled = 1 AND `serial` IS NOT NULL AND `serial` != ''
	]);
	$meter_sth->execute();

	my @serials;
	while (my ($serial) = $meter_sth->fetchrow_array) {
		push @serials, $serial;
	}
	$meter_sth->finish;
	$dbh->disconnect;

	foreach my $serial (@serials) {
		$pm->start and next;

		my $dbh = Nabovarme::Db->my_connect() or die "[$table][$serial] Cannot connect to DB";
		$dbh->{mysql_auto_reconnect} = 1;

		my $select_samples_sth = $dbh->prepare(qq[
			SELECT id, unix_time, ] . join(",", @fields) . qq[
			FROM $table
			WHERE `serial` = ?
			AND is_spike != 1
			ORDER BY unix_time ASC
		]) or die "[$table][$serial] Failed to prepare select: " . $dbh->errstr;

		my $mark_spike_sth = $dbh->prepare("UPDATE $table SET is_spike = 1 WHERE id = ?")
			or die "[$table][$serial] Failed to prepare update: " . $dbh->errstr;

		$select_samples_sth->execute($serial)
			or die "[$table][$serial] Failed to execute select: " . $select_samples_sth->errstr;

		my ($prev, $curr);
		if ($select_samples_sth->rows >= 2) {
			$prev = $select_samples_sth->fetchrow_hashref;
			$curr = $select_samples_sth->fetchrow_hashref;
		} else {
			print "[$table][$serial] Not enough samples — skipping\n";
			$select_samples_sth->finish;
			$mark_spike_sth->finish;
			$dbh->disconnect;
			$pm->finish(0);
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

						# If neighbor is zero, val must be at least spike_factor.
						# If neighbor is positive, val must be spike_factor times larger than neighbor.
						(
							(
								($prev_val == 0 && $val >= $spike_factor) ||
								($prev_val > 0  && $val > $spike_factor * $prev_val)
							)
							&&
							(
								($next_val == 0 && $val >= $spike_factor) ||
								($next_val > 0  && $val > $spike_factor * $next_val)
							)
						)
					)
				) {
					$mark = 1;
					print "[$table][$serial] Marked spike at $curr->{unix_time} on $field:\n";
					print "   prev=$prev_val, curr=$val, next=$next_val\n";
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

		print "[$table][$serial] Done — Marked $count_marked samples as spike\n";

		$select_samples_sth->finish;
		$mark_spike_sth->finish;
		$dbh->disconnect;

		$pm->finish(0);
	}
}

$pm->wait_all_children;
print "All done.\n";
