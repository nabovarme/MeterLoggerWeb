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

# Subroutine to update aggregated samples for each meter
sub update_samples_hourly_and_daily {
	# Prepare and execute SQL to get all meter serials
	$sth = $dbh->prepare(qq[SELECT `serial` FROM meters]);
	$sth->execute;

	print "update samples hourly and daily for all meters\n";

	# Loop through each meter
	while ($d = $sth->fetchrow_hashref) {
		# Escape and quote the serial for safe SQL use
		my $quoted_serial = $dbh->quote($d->{serial});

		print "\tupdate samples_hourly for " . $d->{serial} . "\n";

		# Hourly aggregation in a transaction
		eval {
			# Remove old hourly samples for this meter
			$dbh->do(qq[DELETE FROM `samples_hourly` WHERE `serial` LIKE $quoted_serial]) || warn "$!\n";

			# Insert new hourly averages grouped by hour
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
					`hours`, 
					AVG(`volume`), 
					AVG(`energy`),
					`unix_time`
				FROM `samples` 
				WHERE `serial` LIKE $quoted_serial 
				GROUP BY DATE(FROM_UNIXTIME(`unix_time`)), HOUR(FROM_UNIXTIME(`unix_time`)) 
				ORDER BY FROM_UNIXTIME(`unix_time`) ASC
			]) or warn "$!\n";

			# Commit the transaction
			$dbh->commit();
		};
		if ($@) {
			# Rollback on error
			warn "Error inserting the link and tag: $@\n";
			$dbh->rollback();
		}

		print "\tupdate samples_daily for " . $d->{serial} . "\n";

		# Daily aggregation in a transaction
		eval {
			# Remove old daily samples for this meter
			$dbh->do(qq[DELETE FROM `samples_daily` WHERE `serial` LIKE $quoted_serial]) || warn "$!\n";

			# Insert new daily averages grouped by day
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
					`hours`, 
					AVG(`volume`), 
					AVG(`energy`),
					`unix_time`
				FROM `samples` 
				WHERE `serial` LIKE $quoted_serial 
				GROUP BY DATE(FROM_UNIXTIME(`unix_time`)), DAY(FROM_UNIXTIME(`unix_time`)) 
				ORDER BY FROM_UNIXTIME(`unix_time`) ASC
			]) or warn "$!\n";

			# Commit the transaction
			$dbh->commit();
		};
		if ($@) {
			# Rollback on error
			warn "Error inserting the link and tag: $@\n";
			$dbh->rollback();
		}
	}
}

# End of script
1;

__END__
