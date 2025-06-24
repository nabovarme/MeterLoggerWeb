#!/usr/bin/perl -w
use strict;
use warnings;
use Fcntl ':flock';  # For manual file locking
use DBI;
use Parallel::ForkManager;
use File::Basename;
use Getopt::Long;

use lib qw( /etc/apache2/perl );
use Nabovarme::Db;

$| = 1;  # Autoflush STDOUT

# === COMMAND LINE OPTIONS ===
my $dry_run = 0;
GetOptions('n' => \$dry_run);

if ($dry_run) {
	print "Running in DRY RUN mode: no database updates will be performed.\n";
}

# === LOCKING ===
my $script_name = basename($0);
my $lockfile = "/tmp/$script_name.lock";
open(my $fh, ">", $lockfile) or die "Cannot open lock file $lockfile: $!";
flock($fh, LOCK_EX | LOCK_NB) or die "Another instance is already running. Exiting.\n";
print $fh "$$\n";  # Write current PID to the lock file

# === CONFIGURATION ===

my @tables = ('samples_cache', 'samples');  # Process both tables

my @fields = qw(flow_temp return_flow_temp temp_diff flow effect hours volume energy);

my $spike_factor	 = 10;
my $min_val_threshold = 1 / $spike_factor;

# Max parallel processes
my $max_processes = 4;

# === DB SETUP ===

my $dbh = Nabovarme::Db->my_connect() or die "Cannot connect to DB";
$dbh->{mysql_auto_reconnect} = 1;

my $pm = Parallel::ForkManager->new($max_processes);

my $total_spikes_marked = 0;

for my $table (@tables) {
	print "\n=== Processing table: $table ===\n";

	# Get serials from meters table
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
			next;
		}

		# Child process
		my @log;
		my $child_dbh = Nabovarme::Db->my_connect() or die "Cannot connect to DB";
		$child_dbh->{mysql_auto_reconnect} = 1;

		my $last_spike_unix_time = get_last_spike_time($child_dbh, $table, $serial);
		push @log, "--- Checking serial: $serial ---\n";
		push @log, "  Skipping rows before unix_time = $last_spike_unix_time for serial $serial\n";

		my $sth = $child_dbh->prepare(qq[
			SELECT id, unix_time, is_spike, ] . join(",", @fields) . qq[
			FROM $table
			WHERE serial = ?
			AND is_spike != 1
			AND unix_time > ?
			ORDER BY unix_time ASC
		]);
		$sth->execute($serial, $last_spike_unix_time) or die "Failed to execute: " . $sth->errstr;

		# Preload the sliding window
		my $spikes_marked = 0;
		my $prev = $sth->fetchrow_hashref;
		unless ($prev) {
			push @log, "  No data after last spike for serial $serial in table $table\n";
			$sth->finish;
			$child_dbh->disconnect;
			print @log;
			$pm->finish(0, { serial => $serial, spikes_marked => $spikes_marked });
		}
		push @log, "  First row unix_time: $prev->{unix_time}\n";

		my $curr = $sth->fetchrow_hashref;
		unless ($curr) {
			push @log, "  Not enough data for serial $serial in table $table (only 1 row)\n";
			$sth->finish;
			$child_dbh->disconnect;
			print @log;
			$pm->finish(0, { serial => $serial, spikes_marked => $spikes_marked });
		}

		my $next = $sth->fetchrow_hashref;
		unless ($next) {
			push @log, "  Not enough data for serial $serial in table $table (only 2 rows)\n";
		}

		# If there's not enough data to form a sliding window, skip
		if (!$prev || !$curr || !$next) {
			push @log, "  Not enough samples for serial $serial — skipping\n";
			$sth->finish;
			$child_dbh->disconnect;
			print @log;
			$pm->finish(0, { serial => $serial, spikes_marked => 0 });
		}

		while ($prev && $curr && $next) {
			my ($spike_field, $vals_ref) = is_spike_detected($prev, $curr, $next);

			if ($spike_field) {
				push @log, "  Detected spike at $curr->{unix_time} on $spike_field for serial $serial\n";
				push @log, "	Values: prev=$vals_ref->{prev}, curr=$vals_ref->{curr}, next=$vals_ref->{next}\n";
				push @log, "  Marking spike for serial $serial: id=$curr->{id}\n\n";

				unless ($dry_run) {
					mark_spike($child_dbh, $table, $curr->{id});
				}
				else {
					push @log, "  [DRY RUN] Skipping database update for spike id=$curr->{id}\n";
				}
				$spikes_marked++;
			}

			$prev = $curr;
			$curr = $next;
			$next = $sth->fetchrow_hashref;
		}

		$sth->finish;
		$child_dbh->disconnect;
		print @log;
		$pm->finish(0, { serial => $serial, spikes_marked => $spikes_marked });
	}

	$pm->wait_all_children;

	# Summary per table
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
# Clean up lock file after successful run
close($fh);
unlink $lockfile;

# === SUBROUTINES ===

# Detects spikes in the middle value of the sliding window [prev, curr, next]
sub is_spike_detected {
	my ($prev, $curr, $next) = @_;

	foreach my $field (@fields) {
		my ($val, $prev_val, $next_val) = ($curr->{$field}, $prev->{$field}, $next->{$field});
		next unless defined $val && defined $prev_val && defined $next_val;

		# Skip tiny fluctuations
		next unless ($prev_val >= 1 || $val >= 1 || $next_val >= 1);

		# Handle zero current value — check both neighbors are high
		if ($val == 0) {
			if ($prev_val >= $spike_factor && $next_val >= $spike_factor) {
				return ($field, { prev => $prev_val, curr => $val, next => $next_val });
			}
		}
		# Handle non-zero current value — check it's much higher than both neighbors
		else {
			if (
				(($prev_val == 0 && $val >= $spike_factor) || ($prev_val > 0 && $val >= $spike_factor * $prev_val)) &&
				(($next_val == 0 && $val >= $spike_factor) || ($next_val > 0 && $val >= $spike_factor * $next_val))
			) {
				return ($field, { prev => $prev_val, curr => $val, next => $next_val });
			}
			
			# Inverse spike: current value much smaller than both neighbors
			if (
				$prev_val >= $spike_factor &&
				$next_val >= $spike_factor &&
				$val <= $prev_val / $spike_factor &&
				$val <= $next_val / $spike_factor
			) {
				return ($field, { prev => $prev_val, curr => $val, next => $next_val });
			}
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

# Gets the last spike timestamp for a given serial
sub get_last_spike_time {
	my ($dbh, $table, $serial) = @_;
	my $sth = $dbh->prepare("SELECT MAX(unix_time) FROM $table WHERE serial = ? AND is_spike = 1");
	$sth->execute($serial);
	my ($ts) = $sth->fetchrow_array;
	$sth->finish;
	return $ts || 0;
}

__END__
