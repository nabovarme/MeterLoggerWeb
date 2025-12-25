#!/usr/bin/perl -w

use strict;
use Data::Dumper;
use DBI;
use Config;
use Time::HiRes qw( usleep );

use Nabovarme::Db;
use Nabovarme::Utils;

log_info("starting...");

my $dbh;
my $sth;
my $d;

# connect to db
if ($dbh = Nabovarme::Db->my_connect) {
	$dbh->{'mysql_auto_reconnect'} = 1;
	log_info("connected to db");
}
else {
	log_die("cant't connect to db $!");
}

log_info("cleaning sms_auth");
$dbh->do(qq[DELETE FROM sms_auth WHERE `auth_state` = 'new' AND from_unixtime(`unix_time`) < NOW() - INTERVAL 1 HOUR]) or warn "$!\n";
$dbh->do(qq[DELETE FROM sms_auth WHERE `auth_state` = 'login' AND from_unixtime(`unix_time`) < NOW() - INTERVAL 1 DAY]) or warn "$!\n";
$dbh->do(qq[DELETE FROM sms_auth WHERE `auth_state` = 'sms_code_sent' AND from_unixtime(`unix_time`) < NOW() - INTERVAL 1 DAY]) or warn "$!\n";
log_info("done cleaning sms_auth");

1;

__END__
