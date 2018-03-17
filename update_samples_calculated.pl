#!/usr/bin/perl -w

use strict;
use Data::Dumper;
use Sys::Syslog;
use DBI;
use Config;
use Proc::Pidfile;
use Time::HiRes qw( usleep );

use lib qw( /etc/apache2/perl );
use lib qw( /opt/local/apache2/perl/ );
use Nabovarme::Db;

my $pp = Proc::Pidfile->new();
print Dumper $pp->pidfile();

openlog($0, "ndelay,pid", "local0");
syslog('info', "starting...");

my $dbh;
my $sth;
my $d;

# connect to db
if ($dbh = Nabovarme::Db->my_connect) {
	$dbh->{'mysql_auto_reconnect'} = 1;
	$dbh->{'AutoCommit'} = 0;
	$dbh->{'RaiseError'} = 1;
	syslog('info', "connected to db");
}
else {
	syslog('info', "cant't connect to db $!");
	die $!;
}

update_samples_calculated();
$dbh->disconnect();


sub update_samples_calculated {
	$sth = $dbh->prepare(qq[SELECT `serial` FROM meters]);
	$sth->execute;
	
	syslog('info', "update samples_calculated for all meters");
	while ($d = $sth->fetchrow_hashref) {
		my $quoted_serial = $dbh->quote($d->{serial});

		syslog('info', "    update samples_calculated for " . $d->{serial});
		# re calculate in transaction
		eval {
			$dbh->do(qq[DELETE FROM `samples_calculated` WHERE `serial` LIKE ] . $d->{serial}) || warn $!;
			$dbh->do(qq[INSERT INTO `samples_calculated` (`serial`, `heap`, `flow_temp`, `return_flow_temp`, `temp_diff`, `t3`, `flow`, `effect`, `hours`, `volume`, `energy`, `unix_time`)
							SELECT 
								`serial`, 
								`heap`,
								AVG(`flow_temp`) as `flow_temp`, 
								AVG(`return_flow_temp`) as `return_flow_temp`, 
								AVG(`temp_diff`) as `temp_diff`, 
								AVG(`t3`) as `t3`, 
								AVG(`flow`) as `flow`, 
								AVG(`effect`) as `effect`, 
								`hours`, 
								AVG(`volume`) as `volume`, 
								AVG(`energy`) as `energy`,
								`unix_time`
							FROM `samples` 
							WHERE `serial` LIKE $quoted_serial 
							AND effect IS NOT NULL 
							GROUP BY DATE( FROM_UNIXTIME(`unix_time`) ), HOUR( FROM_UNIXTIME(`unix_time`) ) 
							ORDER BY FROM_UNIXTIME(`unix_time`) ASC]) or warn $!;
							
			$dbh->commit();
		};
		if ($@) {
			warn "Error inserting the link and tag: $@";
			$dbh->rollback();
		}
	}
}

1;

__END__
