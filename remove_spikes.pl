#!/usr/bin/perl -w
use strict;
use warnings;
use Fcntl ':flock';  # For manual file locking
use DBI;
use Parallel::ForkManager;
use File::Basename;

use lib qw( /etc/apache2/perl );
use Nabovarme::Db;

$| = 1;  # Autoflush STDOUT

# === LOCKING ===
my $script_name = basename($0);
my $lockfile = "/tmp/$script_name.lock";
open(my $fh, ">", $lockfile) or die "Cannot open lock file $lockfile: $!";
flock($fh, LOCK_EX | LOCK_NB) or die "Another instance is already running. Exiting.\n";
print $fh "$$\n";  # Write current PID to the lock file

# === CONFIGURATION ===

my @tables = ('samples', 'samples_cache');  # Process both tables

my @fields = qw(flow_temp return_flow_temp flow hours volume energy);

my $spike_factor	 = 10;
my $min_val_threshold = 1 / $spike_factor;

# Max parallel processes
my $max_processes = 8;

# === DB SETUP ===

my $dbh = Nabovarme::Db->my_connect() or die "Cannot connect to DB";
$dbh->{mysql_auto_reconnect} = 1;

my $pm = Parallel::ForkManager->new($max_processes);

my $total_spikes_marked = 0;

for my $table (@tables) {
	print "\n=== Processing table: $table ===\n";

	# Get serials from meters table that are not NULL and enabled
	my $serials_sth = $dbh->prepare(qq[
		SELECT `serial` FROM meters
		WHERE serial IS NOT NULL
		AND enabled = 1
		ORDER BY `serial`]
	);
	$serials_sth->execute();
	my @serials;
	while (my ($serial) = $serials_sth->fetchrow_array) {
		push @serials, $serial;
	}
	$serials_sth->finish;

	my %serial_spikes;

	# Gather spike count from children
	$pm->run_on_finish(sub {
		my ($pid, $exit_code, $ident, $exit_signal, $core_dump, $data_ref) = @_;
		if (defined $data_ref && ref $data_ref eq 'HASH') {
			$serial_spikes{$data_ref->{serial}} = $data_ref->{spikes_marked};
			$total_spikes_marked += $data_ref->{spikes_marked};
		}
	});

	# Process each serial in parallel
	foreach my $serial (@serials) {
		my $pid = $pm->start($serial);
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

		my $spikes_marked = 0;

		while ($prev && $curr && $next) {
			my ($spike_field, $vals_ref) = is_spike_detected($prev, $curr, $next);

			if ($spike_field) {
				print "  Detected spike at $curr->{unix_time} on $spike_field for serial $serial\n";
				print "	Values: prev=$vals_ref->{prev}, curr=$vals_ref->{curr}, next=$vals_ref->{next}\n";
				print "  Marking spike for serial $serial: id=$curr->{id}\n\n";
				mark_spike($child_dbh, $table, $curr->{id});
				$spikes_marked++;
			}

			$prev = $curr;
			$curr = $next;
			$next = $sth->fetchrow_hashref;
		}

		$sth->finish;
		$child_dbh->disconnect;

		$pm->finish(0, { serial => $serial, spikes_marked => $spikes_marked });
	}

	$pm->wait_all_children;

	print "\nSummary for table '$table':\n";
	my $table_total = 0;
	foreach my $serial (sort keys %serial_spikes) {
		my $count = $serial_spikes{$serial} || 0;
		print "  Serial $serial: $count spikes marked\n";
		$table_total += $count;
	}
	print "  Total spikes marked in table '$table': $table_total\n";
}

$dbh->disconnect;

print "\nDone.\n";
print "Total spikes marked in all tables: $total_spikes_marked\n";

# === UNLOCKING ===
close($fh);
unlink $lockfile;  # optional: remove the lock file

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
	$update->finish;
}

__END__
