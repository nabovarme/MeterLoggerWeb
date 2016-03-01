#!/usr/bin/perl -w

use strict;
use Data::Dumper;
use Sys::Syslog;
use Net::MQTT::Simple;
use DBI;

#use lib qw( /var/www/perl/lib/ );
use lib qw( /opt/local/apache2/perl/ );
use Nabovarme::Db;

openlog($0, "ndelay,pid", "local0");
syslog('info', "starting...");

my $unix_time;
my $meter_serial;
my $mqtt = Net::MQTT::Simple->new(q[loppen.christiania.org]);
my $mqtt_data = undef;
#my $mqtt_count = 0;

# connect to db
my $dbh;
my $sth;
my $d;

if ($dbh = Nabovarme::Db->my_connect) {
	$dbh->{'mysql_auto_reconnect'} = 1;
	syslog('info', "connected to db");
}
else {
	syslog('info', "cant't connect to db $!");
	die $!;
}

$sth = $dbh->prepare(qq[SELECT `serial`,`info` FROM meters WHERE `serial` IN (SELECT DISTINCT(`serial`) `serial` FROM samples)]);
$sth->execute;

while ($d = $sth->fetchrow_hashref) {
	print Dumper $d->{serial};
	$mqtt->retain('/config/v1/' . $d->{serial} . '/version' => 'retain');
	$mqtt->retain('/config/v1/' . $d->{serial} . '/status' => 'retain');
}

# end of main
