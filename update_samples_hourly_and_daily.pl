#!/usr/bin/perl -w

use strict;
use Data::Dumper;
use DBI;
use Config;
use Time::HiRes qw( usleep );

# Include custom library path
use lib qw( /etc/apache2/perl );
use Nabovarme::Db;

# Autoflush STDOUT to ensure immediate output
$| = 1;

print "starting...\n";

# Declare database handle and variables
my $dbh;
my $sth;
my $d;

# Connect to the database using a custom DB module
if ($dbh = Nabovarme::Db->my_connect) {
	# Enable automatic reconnection to MySQL
	$dbh->{'mysql_auto_reconnect'} = 1;

	# Disable auto-commit mode, so we can use transactions
	$dbh->{'AutoCommit'} = 0;

	# Automatically raise errors as exceptions
	$dbh->{'RaiseError'} = 1;

	print "connected to db\n";
}
else {
	# Connection failed; print error and exit
	print "cant't connect to db $!\n";
	die $!;
}

# Call the subroutine to update hourly and daily samples
update_samples_hourly_and_daily();

# Disconnect from the database
$dbh->disconnect();

# Subroutine to update hourly and daily samples incrementally for each meter
sub update_samples_hourly_and_daily {
	# Prepare and execute SQL to get all meter serials
	$sth = $dbh->prepare(qq[SELECT `serial` FROM meters]);
	$sth->execute;

	print "update samples_hourly and samples_daily for all meters\n";

	# Loop through each meter
	while ($d = $sth->fetchrow_hashref) {
		my $serial = $d->{serial};
		my $quoted_serial = $dbh->quote($serial);  # safely quote for SQL

		# Get the latest aggregation times to avoid re-processing old data
		my $last_hourly = $dbh->selectrow_array(
			"SELECT MAX(unix_time) FROM samples_hourly WHERE serial = $quoted_serial"
		) || 0;

		my $last_daily = $dbh->selectrow_array(
			"SELECT MAX(unix_time) FROM samples_daily WHERE serial = $quoted_serial"
		) || 0;

		# === HOURLY AGGREGATION ===
		print "\tupdate samples_hourly for $serial from $last_hourly\n";

		eval {
			# Insert new hourly aggregates only for data newer than last aggregation
			$dbh->do(qq[
				INSERT INTO `samples_hourly`
				(`serial`, `heap`, `flow_temp`, `return_flow_temp`, `temp_diff`, `t3`, `flow`, `effect`, `hours`, `volume`, `energy`, `unix_time`)
				SELECT 
					`serial`,
					`heap`,
					AVG(`flow_temp`),
					AVG(`return_flow_temp`),
					AVG(`temp_diff`),
					AVG(`t3`),
					AVG(`flow`),
					AVG(`effect`),
					MAX(`hours`),  -- assuming hours is a counter and we want the latest
					AVG(`volume`),
					AVG(`energy`),
					FLOOR(unix_time / 3600) * 3600 AS `unix_time`  -- group by hour
				FROM `samples`
				WHERE `serial` = $quoted_serial AND `unix_time` > $last_hourly
				GROUP BY FLOOR(`unix_time` / 3600)
				ORDER BY `unix_time` ASC
			]);

			# Commit the transaction after hourly insert
			$dbh->commit();
		};
		if ($@) {
			# Roll back the transaction if an error occurs
			warn "Error updating samples_hourly for $serial: $@\n";
			$dbh->rollback();
		}

		# === DAILY AGGREGATION ===
		print "\tupdate samples_daily for $serial from $last_daily\n";

		eval {
			# Insert new daily aggregates only for data newer than last aggregation
			$dbh->do(qq[
				INSERT INTO `samples_daily`
				(`serial`, `heap`, `flow_temp`, `return_flow_temp`, `temp_diff`, `t3`, `flow`, `effect`, `hours`, `volume`, `energy`, `unix_time`)
				SELECT 
					`serial`,
					`heap`,
					AVG(`flow_temp`),
					AVG(`return_flow_temp`),
					AVG(`temp_diff`),
					AVG(`t3`),
					AVG(`flow`),
					AVG(`effect`),
					MAX(`hours`),
					AVG(`volume`),
					AVG(`energy`),
					FLOOR(unix_time / 86400) * 86400 AS `unix_time`  -- group by day
				FROM `samples`
				WHERE `serial` = $quoted_serial AND `unix_time` > $last_daily
				GROUP BY FLOOR(`unix_time` / 86400)
				ORDER BY `unix_time` ASC
			]);

			# Commit the transaction after daily insert
			$dbh->commit();
		};
		if ($@) {
			# Roll back the transaction if an error occurs
			warn "Error updating samples_daily for $serial: $@\n";
			$dbh->rollback();
		}
	}
}

# End of script
1;

__END__
