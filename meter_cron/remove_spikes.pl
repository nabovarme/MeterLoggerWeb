#!/usr/bin/perl -w
use strict;
use warnings;
use Fcntl ':flock';  # For manual file locking
use DBI;
use Parallel::ForkManager;
use File::Basename;
use Getopt::Long;

use Nabovarme::Db;
use Nabovarme::Utils;

$| = 1;  # Autoflush STDOUT

# === COMMAND LINE OPTIONS ===
my $dry_run = 0;
GetOptions('n' => \$dry_run);

if ($dry_run) {
	log_info("Running in DRY RUN mode: no database updates will be performed.");
}

# === LOCKING ===
my $script_name = basename($0);
my $lockfile = "/tmp/$script_name.lock";
open(my $fh, ">", $lockfile) or log_die("Cannot open lock file $lockfile: $!");
flock($fh, LOCK_EX | LOCK_NB) or log_die("Another instance is already running. Exiting.");
print $fh "$$\n";  # Write current PID to the lock file

# === CONFIGURATION ===

my @tables = ('samples_cache', 'samples');  # Process both tables

my @fields = qw(flow_temp return_flow_temp temp_diff flow effect hours volume energy);

my $SPIKE_FACTOR	 = 10;

# Max parallel processes
my $MAX_PROCESSES = 4;

# === DB SETUP ===

my $dbh = Nabovarme::Db->my_connect() or die "Cannot connect to DB";
$dbh->{mysql_auto_reconnect} = 1;

my $pm = Parallel::ForkManager->new($MAX_PROCESSES);

my $total_spikes_marked = 0;

for my $table (@tables) {
	log_info("=== Processing table: $table ===");

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

	# === PRELOAD LAST SPIKE TIMES ===
	my %last_spike_times;
	my $spike_times_sth = $dbh->prepare(qq[
		SELECT serial, MAX(unix_time) as last_time
		FROM $table
		WHERE is_spike = 1
		GROUP BY serial
	]);
	$spike_times_sth->execute();
	while (my ($serial, $last_time) = $spike_times_sth->fetchrow_array) {
		$last_spike_times{$serial} = $last_time;
	}
	$spike_times_sth->finish;

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

		# === CHILD PROCESS ===
		my @log;
		my $child_dbh = Nabovarme::Db->my_connect() or die "Cannot connect to DB";
		$child_dbh->{mysql_auto_reconnect} = 1;

		my $last_spike_unix_time = $last_spike_times{$serial} || 0;

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
			log_info(@log);
			$pm->finish(0, { serial => $serial, spikes_marked => $spikes_marked });
		}
		push @log, "  First row unix_time: $prev->{unix_time}\n";

		my $curr = $sth->fetchrow_hashref;
		unless ($curr) {
			push @log, "  Not enough data for serial $serial in table $table (only 1 row)\n";
			$sth->finish;
			$child_dbh->disconnect;
			log_info(@log);
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
			log_info(@log);
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
		log_info(@log);
		$pm->finish(0, { serial => $serial, spikes_marked => $spikes_marked });
	}

	$pm->wait_all_children;

	# Summary per table
	log_info("Summary for table '$table':");
	my $table_total = 0;
	foreach my $serial (sort keys %serial_spikes) {
		my $count = $serial_spikes{$serial} || 0;
		log_info("  Serial $serial: $count spikes marked");
		$table_total += $count;
	}
	log_info("  Total spikes marked in table '$table': $table_total");
}

$dbh->disconnect;

log_info("Done.");
log_info("Total spikes marked in all tables: $total_spikes_marked");

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

		# max/min calculation
		my $max = $val;
		$max = $prev_val if $prev_val > $max;
		$max = $next_val if $next_val > $max;

		my $min = $val;
		$min = $prev_val if $prev_val < $min;
		$min = $next_val if $next_val < $min;

		# Skip small absolute values
		next if $val <= $SPIKE_FACTOR && $prev_val <= $SPIKE_FACTOR && $next_val <= $SPIKE_FACTOR;

		# Skip if values are within a narrow fluctuation range
		if ($min > 0 && ($max / $min) < $SPIKE_FACTOR) {
			next;
		}

		# Inverted spike: middle is zero, neighbors are high
		if ($val == 0 && $prev_val >= $SPIKE_FACTOR && $next_val >= $SPIKE_FACTOR) {
			return ($field, { prev => $prev_val, curr => $val, next => $next_val });
		}

		# Regular spike: middle is much higher than neighbors
		if (
			(($prev_val == 0 && $val >= $SPIKE_FACTOR) || ($prev_val > 0 && $val >= $SPIKE_FACTOR * $prev_val)) &&
			(($next_val == 0 && $val >= $SPIKE_FACTOR) || ($next_val > 0 && $val >= $SPIKE_FACTOR * $next_val))
		) {
			return ($field, { prev => $prev_val, curr => $val, next => $next_val });
		}

		# Inverse spike: middle is much lower than neighbors
		if (
			$prev_val >= $SPIKE_FACTOR &&
			$next_val >= $SPIKE_FACTOR &&
			$val <= $prev_val / $SPIKE_FACTOR &&
			$val <= $next_val / $SPIKE_FACTOR
		) {
			return ($field, { prev => $prev_val, curr => $val, next => $next_val });
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
