#!/usr/bin/perl -w

use strict;
use Data::Dumper;
use DBI;
use Config;
use Time::HiRes qw(usleep);
use POSIX ":sys_wait_h";

# Include custom library path
use lib qw( /etc/apache2/perl );
use Nabovarme::Db;

# Autoflush STDOUT to ensure immediate output
$| = 1;

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
$sth = $dbh->prepare(qq[SELECT `serial` FROM meters]);
$sth->execute;

my @serials;
while (my $row = $sth->fetchrow_hashref) {
	push @serials, $row->{serial};
}

$dbh->disconnect();  # Close parent DB connection before forking

# Max concurrent processes
my $MAX_PROCESSES = 4;
my @children;

foreach my $serial (@serials) {
	# Limit concurrency
	while (@children >= $MAX_PROCESSES) {
		my $pid = wait();
		@children = grep { $_ != $pid } @children;
	}

	my $pid = fork();
	if (!defined $pid) {
		warn "Failed to fork for $serial: $!";
		next;
	}

	if ($pid == 0) {
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
				WHERE `serial` = $quoted_serial AND `unix_time` > $last_hourly
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
				WHERE `serial` = $quoted_serial AND `unix_time` > $last_daily
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
	} else {
		# Parent process adds PID to list
		push @children, $pid;
	}
}

# Wait for all remaining child processes to finish
while (@children) {
	my $pid = wait();
	@children = grep { $_ != $pid } @children;
}

print "All serials processed.\n";

# End of script
1;

__END__
