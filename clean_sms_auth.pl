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

syslog('info', "cleaning sms_auth");
$dbh->do(qq[DELETE FROM sms_auth WHERE `auth_state` = 'new' AND from_unixtime(`unix_time`) < NOW() - INTERVAL 1 HOUR]) or warn $!;
$dbh->do(qq[DELETE FROM sms_auth WHERE `auth_state` = 'sms_code_sent' AND from_unixtime(`unix_time`) < NOW() - INTERVAL 1 DAY]) or warn $!;

1;

__END__
