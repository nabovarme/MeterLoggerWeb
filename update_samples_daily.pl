#!/usr/bin/perl -w

use strict;
use Data::Dumper;
use DBI;
use Config;
use Time::HiRes qw( usleep );

use lib qw( /etc/apache2/perl );
use Nabovarme::Db;

warn("starting...\n");

my $dbh;
my $sth;
my $d;

# connect to db
if ($dbh = Nabovarme::Db->my_connect) {
	$dbh->{'mysql_auto_reconnect'} = 1;
	$dbh->{'AutoCommit'} = 0;
	$dbh->{'RaiseError'} = 1;
	warn("connected to db\n");
}
else {
	warn("cant't connect to db $!\n");
	die $!;
}

update_samples_daily();
$dbh->disconnect();


sub update_samples_daily {
	warn("update samples_daily for all meters\n");

	# re calculate in transaction
	eval {
		$dbh->do(qq[DELETE FROM samples_daily]) || warn "$!\n";
		$dbh->do(qq[
		INSERT INTO samples_daily (
			`serial`, heap, flow_temp, return_flow_temp, temp_diff,
			t3, flow, effect, hours, volume, energy, unix_time
		)
		SELECT
			s.`serial`, s.heap, s.flow_temp, s.return_flow_temp, s.temp_diff,
			s.t3, s.flow, s.effect, s.hours, s.volume, s.energy, s.unix_time
		FROM samples s
		JOIN (
			SELECT 
				`serial`,
				DATE(FROM_UNIXTIME(unix_time)) AS sample_day,
				MIN(unix_time) AS first_unix_time
			FROM samples
			GROUP BY `serial`, sample_day
		) first_samples 
			ON s.`serial` = first_samples.`serial` 
			AND s.unix_time = first_samples.first_unix_time;
		]) or warn "$!\n";
		$dbh->commit();
	};
	if ($@) {
		warn "Error inserting the link and tag: $@\n";
		$dbh->rollback();
	}
}

1;

__END__
