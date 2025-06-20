#!/usr/bin/perl -w

use strict;
use Data::Dumper;
use DBI;
use Config;
use Time::HiRes qw( usleep );

use lib qw( /etc/apache2/perl );
use Nabovarme::Db;

$SIG{USR1} = \&clean_samples_cache;

$SIG{INT} = \&sig_int_handler;

warn("starting...\n");

my $dbh;
my $sth;
my $d;

# connect to db
if ($dbh = Nabovarme::Db->my_connect) {
	$dbh->{'mysql_auto_reconnect'} = 1;
	warn("connected to db\n");
}
else {
	warn("cant't connect to db $!\n");
	die $!;
}

clean_samples_cache();
while (1) {
	sleep 60;
}

sub clean_samples_cache {
	$sth = $dbh->prepare(qq[SELECT `serial`, `key` FROM meters WHERE `key` is not NULL]);
	$sth->execute;
	
	warn("cleaning samples_cache for all meters\n");
	while ($d = $sth->fetchrow_hashref) {
		my $quoted_serial = $dbh->quote($d->{serial});

		warn("\tcleaning samples_cache for " . $d->{serial} . "\n");
		# send scan
		$dbh->do(qq[DELETE FROM `samples_cache` WHERE SERIAL LIKE $quoted_serial AND `id` NOT IN ( \
						SELECT `id` FROM (
							SELECT a.`id` FROM (
							SELECT * FROM nabovarme.samples_cache 
							WHERE `serial` LIKE $quoted_serial 
							AND FROM_UNIXTIME(`unix_time`) < NOW() - INTERVAL 7 DAY 
							ORDER BY `unix_time` DESC LIMIT 5
						) a
						UNION SELECT b.`id` FROM (
						SELECT * FROM nabovarme.samples_cache 
							WHERE `serial` LIKE $quoted_serial 
							AND FROM_UNIXTIME(`unix_time`) >= NOW() - INTERVAL 7 DAY 
							ORDER BY `unix_time` DESC
						) b
						) save_list
					)]) or warn "$!\n";
	}
}

sub sig_int_handler {

	die $!;
}

1;

__END__
