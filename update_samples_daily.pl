#!/usr/bin/perl -w

use strict;
use Data::Dumper;
use DBI;
use Config;
use Time::HiRes qw( usleep );

use lib qw( /etc/apache2/perl );
use Nabovarme::Db;

$| = 1;	# Autoflush STDOUT

print "starting...\n";

my $dbh;
my $sth;
my $d;

# connect to db
if ($dbh = Nabovarme::Db->my_connect) {
	$dbh->{'mysql_auto_reconnect'} = 1;
	$dbh->{'AutoCommit'} = 0;
	$dbh->{'RaiseError'} = 1;
	print "connected to db\n";
}
else {
	print "cant't connect to db $!\n";
	die $!;
}

update_samples_daily();
$dbh->disconnect();


sub update_samples_daily {
	$sth = $dbh->prepare(qq[SELECT `serial`, `key` FROM meters WHERE `key` is not NULL]);
	$sth->execute;
	
	print "cleaning samples_cache for all meters\n";
	while ($d = $sth->fetchrow_hashref) {
		my $quoted_serial = $dbh->quote($d->{serial});

		print "\tcleaning samples_cache for " . $d->{serial} . "\n";
	
		# re calculate in transaction
		eval {
			$dbh->do(qq[DELETE FROM samples_daily]) || warn "$!\n";
			$dbh->do(qq[
				INSERT INTO samples_daily (
					`serial`, heap, flow_temp, return_flow_temp, temp_diff,
					t3, flow, effect, hours, volume, energy, unix_time
				)
				SELECT 
					`serial`, heap, flow_temp, return_flow_temp, temp_diff,
					t3, flow, effect, hours, volume, energy, unix_time
				FROM (
					SELECT 
						s.*,
						ROW_NUMBER() OVER (
							PARTITION BY `serial`, DATE(FROM_UNIXTIME(unix_time))
							ORDER BY unix_time ASC
						) AS rn
					FROM samples s
					WHERE serial = $quoted_serial
				) sub
				WHERE rn = 1]) or warn "$!\n";
			$dbh->commit();
		};
		if ($@) {
			warn "Error inserting the link and tag: $@\n";
			$dbh->rollback();
		}
	}
}

1;

__END__
