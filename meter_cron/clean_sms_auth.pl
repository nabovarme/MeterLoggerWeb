#!/usr/bin/perl -w

use strict;
use Data::Dumper;
use DBI;
use Config;
use Time::HiRes qw( usleep );

use Nabovarme::Db;

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

warn("cleaning sms_auth\n");
$dbh->do(qq[DELETE FROM sms_auth WHERE `auth_state` = 'new' AND from_unixtime(`unix_time`) < NOW() - INTERVAL 1 HOUR]) or warn "$!\n";
$dbh->do(qq[DELETE FROM sms_auth WHERE `auth_state` = 'login' AND from_unixtime(`unix_time`) < NOW() - INTERVAL 1 DAY]) or warn "$!\n";
$dbh->do(qq[DELETE FROM sms_auth WHERE `auth_state` = 'sms_code_sent' AND from_unixtime(`unix_time`) < NOW() - INTERVAL 1 DAY]) or warn "$!\n";

1;

__END__
