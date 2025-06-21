#!/usr/bin/perl -w
use strict;
use warnings;
use DBI;
use Parallel::ForkManager;

use lib qw( /etc/apache2/perl );
use Nabovarme::Db;

$| = 1;  # Autoflush STDOUT

# === CONFIGURATION ===

my @tables = ('samples', 'samples_cache');  # Process both tables

my @fields = qw(flow_temp return_flow_temp flow hours volume energy);

my $time_threshold	= 120;
my $spike_factor	  = 10;
my $min_val_threshold = 1 / $spike_factor;

# Max parallel processes
my $max_processes = 4;

# === DB SETUP ===

my $dbh = Nabovarme::Db->my_connect() or die "Cannot connect to DB";
$dbh->{mysql_auto_reconnect} = 1;

my $pm = Parallel::ForkManager->new($max_processes);

for my $table (@tables) {
	print "\n=== Processing table: $table ===\n";

	# Get serials for this table
	my $serials_sth = $dbh->prepare("SELECT DISTINCT serial FROM $table WHERE is_spike != 1");
	$serials_sth->execute();
	my @serials;
	while (my ($serial) = $serials_sth->fetchrow_array) {
		push @serials, $serial;
	}
	$serials_sth->finish;

	# Process each serial in parallel
	foreach my $serial (@serials) {
		my $pid = $pm->start;
		if ($pid) {
			# parent just moves on to next serial
			next;
		}

		# child process:
		my $child_dbh = Nabovarme::Db->my_connect() or die "Cannot connect to DB";
		$child_dbh->{mysql_auto_reconnect} = 1;

		print "\n--- Checking serial: $serial ---\n";

		my $sth = $child_dbh->prepare(qq[
			SELECT id, unix_time, is_spike, ] . join(",", @fields) . qq[
			FROM $table
			WHERE serial = ?
			AND is_spike != 1
			ORDER BY unix_time ASC
		]);
		$sth->execute($serial) or die "Failed to execute: " . $sth->errstr;

		my $prev = $sth->fetchrow_hashref;
		my $curr = $sth->fetchrow_hashref;
		my $next = $sth->fetchrow_hashref;

		while ($prev && $curr && $next) {
			my $prev_diff = abs($curr->{unix_time} - $prev->{unix_time});
			my $next_diff = abs($next->{unix_time} - $curr->{unix_time});

			if ($prev_diff > $time_threshold || $next_diff > $time_threshold) {
				print "  Time gap too large, skipping\n\n";
				$prev = $curr;
				$curr = $next;
				$next = $sth->fetchrow_hashref;
				next;
			}

			my ($spike_field, $vals_ref) = is_spike_detected($prev, $curr, $next);

			if ($spike_field) {
				print "  Detected spike at $curr->{unix_time} on $spike_field\n";
				print "	Values: prev=$vals_ref->{prev}, curr=$vals_ref->{curr}, next=$vals_ref->{next}\n";
				mark_spike($child_dbh, $table, $curr->{id});
			} else {
				print "\n";
			}

			$prev = $curr;
			$curr = $next;
			$next = $sth->fetchrow_hashref;
		}

		$sth->finish;
		$child_dbh->disconnect;

		$pm->finish;  # Terminate child process
	}
}

$pm->wait_all_children;

$dbh->disconnect;

print "\nDone.\n";

# === SUBROUTINES ===

# Detects spikes in the middle value of the sliding window [prev, curr, next]
sub is_spike_detected {
	my ($prev, $curr, $next) = @_;

	foreach my $field (@fields) {
		my ($val, $prev_val, $next_val) = ($curr->{$field}, $prev->{$field}, $next->{$field});
		next unless defined $val && defined $prev_val && defined $next_val;

		# We only consider values where at least one of the three points is >= 1,
		# to ignore noise or near-zero fluctuations.
		if (($prev_val >= 1 || $val >= 1 || $next_val >= 1) && (
			
			# Case 1: Current value is significantly high, neighbors both zero.
			# This indicates a sudden isolated spike upward.
			($val > $spike_factor && $prev_val == 0 && $next_val == 0) ||

			# Case 2: Current value is zero, neighbors are both significantly high.
			# This indicates an inverted spike (sudden drop).
			($val == 0 && $prev_val > $spike_factor && $next_val > $spike_factor) ||

			# Case 3: Current value is small but neighbors are much larger.
			# Checks if current is significantly smaller than both neighbors.
			($val >= $min_val_threshold &&
			 $prev_val > $spike_factor * $val &&
			 $next_val > $spike_factor * $val) ||

			# Case 4: Current value is large compared to neighbors.
			# Both neighbors are either zero or small, while current is much larger.
			(
				(($prev_val == 0 && $val >= $spike_factor) ||
				 ($prev_val > 0 && $val > $spike_factor * $prev_val)) &&
				(($next_val == 0 && $val >= $spike_factor) ||
				 ($next_val > 0 && $val > $spike_factor * $next_val))
			)
		)) {
			return ($field, {
				prev => $prev_val,
				curr => $val,
				next => $next_val,
			});
		}
	}
	return;
}

# Marks a spike row in the database
sub mark_spike {
	my ($dbh, $table, $id) = @_;
	my $update = $dbh->prepare("UPDATE $table SET is_spike = 1 WHERE id = ?");
	$update->execute($id);
	print "  Marking spike: UPDATE $table SET is_spike=1 WHERE id=$id\n\n";
	$update->finish;
}

__END__
