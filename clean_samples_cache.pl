#!/usr/bin/perl -w

use strict;
use Data::Dumper;
use DBI;
use Time::HiRes qw( usleep );

use Nabovarme::Db;
use Nabovarme::Utils;

$SIG{USR1} = \&clean_samples_cache;

$SIG{INT} = \&sig_int_handler;

log_info("starting...");

my $dbh;
my $sth;
my $d;

# connect to db
if ($dbh = Nabovarme::Db->my_connect) {
	$dbh->{'mysql_auto_reconnect'} = 1;
	log_info("connected to db\n");
}
else {
	log_warn("cant't connect to db $!");
	die $!;
}

clean_samples_cache();
while (1) {
	sleep 60;
}

sub clean_samples_cache {
	$sth = $dbh->prepare(qq[SELECT `serial`, `key` FROM meters WHERE `key` is not NULL]);
	$sth->execute;
	
	log_info("cleaning samples_cache for all meters");
	while ($d = $sth->fetchrow_hashref) {
		my $quoted_serial = $dbh->quote($d->{serial});

		log_info("cleaning samples_cache for " . $d->{serial});
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
					)]) or log_warn($DBI::errstr);
	}
}

sub sig_int_handler {
	log_die("Interrupted" . $!);
}

1;

__END__
