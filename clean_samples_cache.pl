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

$SIG{USR1} = \&clean_samples_cache;

$SIG{INT} = \&sig_int_handler;

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
	syslog('info', "connected to db");
}
else {
	syslog('info', "cant't connect to db $!");
	die $!;
}

clean_samples_cache();
while (1) {
	sleep 60;
}

sub clean_samples_cache {
	$sth = $dbh->prepare(qq[SELECT `serial`, `key` FROM meters WHERE `key` is not NULL]);
	$sth->execute;
	
	syslog('info', "cleaning samples_cache for all meters");
	while ($d = $sth->fetchrow_hashref) {
		my $quoted_serial = $dbh->quote($d->{serial});

		syslog('info', "\tcleaning samples_cache for " . $d->{serial});
		# send scan
		$dbh->do(qq[DELETE FROM `samples_cache` WHERE SERIAL LIKE $quoted_serial AND `id` NOT IN ( \
						SELECT `id` FROM (
							SELECT a.`id` FROM (
							SELECT * FROM nabovarme.samples_cache 
							WHERE `serial` LIKE $quoted_serial 
							AND FROM_UNIXTIME(`unix_time`) < NOW() - INTERVAL 24 HOUR 
							ORDER BY `unix_time` DESC LIMIT 3
						) a
						UNION SELECT b.`id` FROM (
						SELECT * FROM nabovarme.samples_cache 
							WHERE `serial` LIKE $quoted_serial 
							AND FROM_UNIXTIME(`unix_time`) >= NOW() - INTERVAL 24 HOUR 
							ORDER BY `unix_time` DESC
						) b
						) save_list
					)]) or warn $!;
	}
}

sub sig_int_handler {

	die $!;
}

1;

__END__
