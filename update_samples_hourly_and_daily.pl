#!/usr/bin/perl -w

use strict;
use Data::Dumper;
use DBI;
use Config;
use Time::HiRes qw(usleep);
use POSIX ":sys_wait_h";
use Fcntl qw(:flock);
use File::Basename;
use Parallel::ForkManager;

# Include custom library path
use lib qw( /etc/apache2/perl );
use Nabovarme::Db;

# === LOCKING ===
my $script_name = basename($0);
my $lockfile = "/tmp/$script_name.lock";

open(my $LOCKFH, '>', $lockfile) or die "Cannot open lock file $lockfile: $!";
unless (flock($LOCKFH, LOCK_EX | LOCK_NB)) {
	die "Another instance of $script_name is already running. Exiting.\n";
}

# Optional: write PID to lock file
print $LOCKFH "$$\n";

# Autoflush STDOUT to ensure immediate output
$| = 1;

# Max concurrent processes
my $MAX_PROCESSES = 4;

print "starting...\n";

# Declare database handle and variables
my $dbh;
my $sth;

# Connect to the database using a custom DB module
if ($dbh = Nabovarme::Db->my_connect) {
	# Enable automatic reconnection to MySQL
	$dbh->{'mysql_auto_reconnect'} = 1;

	# Disable auto-commit mode, so we can use transactions
	$dbh->{'AutoCommit'} = 0;

	# Automatically raise errors as exceptions
	$dbh->{'RaiseError'} = 1;

	print "connected to db\n";
} else {
	# Connection failed; print error and exit
	print "can't connect to db $!\n";
	die $!;
}

# Prepare and execute SQL to get all meter serials
$sth = $dbh->prepare(qq[SELECT `serial` FROM meters ORDER BY `serial`]);
$sth->execute;

my @serials;
while (my $row = $sth->fetchrow_hashref) {
	push @serials, $row->{serial};
}

$dbh->disconnect();  # Close parent DB connection before forking

my $pm = Parallel::ForkManager->new($MAX_PROCESSES);

foreach my $serial (@serials) {
	$pm->start and next;

	# === CHILD PROCESS ===

	# Each child must establish its own DB connection
	my $dbh = Nabovarme::Db->my_connect;
	$dbh->{'mysql_auto_reconnect'} = 1;
	$dbh->{'AutoCommit'} = 0;
	$dbh->{'RaiseError'} = 1;

	my $quoted_serial = $dbh->quote($serial);
	print "processing $serial (PID $$)\n";

	eval {
		# HOURLY aggregation
		my $last_hourly = $dbh->selectrow_array(
			"SELECT MAX(unix_time) FROM samples_hourly WHERE serial = $quoted_serial"
		) || 0;

		$dbh->do(qq[
			INSERT INTO samples_hourly
			(`serial`, `heap`, `flow_temp`, `return_flow_temp`, `temp_diff`, `t3`, `flow`, `effect`, `hours`, `volume`, `energy`, `unix_time`)
			SELECT `serial`, `heap`,
				AVG(`flow_temp`), AVG(`return_flow_temp`), AVG(`temp_diff`),
				AVG(`t3`), AVG(`flow`), AVG(`effect`), MAX(`hours`),
				AVG(`volume`), AVG(`energy`),
				FLOOR(unix_time / 3600) * 3600
			FROM samples
			WHERE `serial` = $quoted_serial
			AND `unix_time` > $last_hourly
			AND `is_spike` != 1
			GROUP BY FLOOR(unix_time / 3600)
		]);
		$dbh->commit();

		# DAILY aggregation
		my $last_daily = $dbh->selectrow_array(
			"SELECT MAX(unix_time) FROM samples_daily WHERE serial = $quoted_serial"
		) || 0;

		$dbh->do(qq[
			INSERT INTO samples_daily
			(`serial`, `heap`, `flow_temp`, `return_flow_temp`, `temp_diff`, `t3`, `flow`, `effect`, `hours`, `volume`, `energy`, `unix_time`)
			SELECT `serial`, `heap`,
				AVG(`flow_temp`), AVG(`return_flow_temp`), AVG(`temp_diff`),
				AVG(`t3`), AVG(`flow`), AVG(`effect`), MAX(`hours`),
				AVG(`volume`), AVG(`energy`),
				FLOOR(unix_time / 86400) * 86400
			FROM samples
			WHERE `serial` = $quoted_serial
			AND `unix_time` > $last_daily
			AND `is_spike` != 1
			GROUP BY FLOOR(unix_time / 86400)
		]);
		$dbh->commit();
	};
	if ($@) {
		warn "Error processing $serial in child $$: $@\n";
		$dbh->rollback();
	}

	$dbh->disconnect();
	exit 0;
	
	$pm->finish;
}

$pm->wait_all_children;

print "All serials processed.\n";

# End of script
1;

__END__
