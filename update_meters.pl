#!/usr/bin/perl -w

use strict;
use Data::Dumper;
use Sys::Syslog;
use Net::MQTT::Simple;
use DBI;

use lib qw( /var/www/perl/lib/ );
#use lib qw( /opt/local/apache2/perl/ );
use Nabovarme::Db;

openlog($0, "ndelay,pid", "local0");
syslog('info', "starting...");

my $unix_time;
my $meter_serial;
my $mqtt = Net::MQTT::Simple->new(q[loppen.christiania.org]);
my $mqtt_data = undef;
#my $mqtt_count = 0;

my $dbh;
my $sth;
my $sth_kwh_left;
my $sth_valve_status;
my $d;
my $d_kwh_left;
my $d_valve_status;

# connect to db
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

syslog('info', "send mqtt retain to all meters for version and status");
while ($d = $sth->fetchrow_hashref) {
	my $quoted_serial = $dbh->quote($d->{serial});
	#print Dumper {serial => $d->{serial}};
	$mqtt->retain('/config/v1/' . $d->{serial} . '/version' => 'retain');
	$mqtt->retain('/config/v1/' . $d->{serial} . '/status' => 'retain');
	$mqtt->retain('/config/v1/' . $d->{serial} . '/uptime' => 'retain');
}

while (1) {
	# open or close valve according to payment status
	$sth = $dbh->prepare(qq[SELECT `serial`, `info`, `min_amount` FROM meters WHERE `serial` IN (SELECT DISTINCT(`serial`) `serial` FROM samples)]);
	$sth->execute;
	
	while ($d = $sth->fetchrow_hashref) {
		my $quoted_serial = $dbh->quote($d->{serial});
		#syslog('info', "serial #" . $d->{serial});
		
		# get kWh left from db
		$sth_kwh_left = $dbh->prepare(qq[SELECT ROUND( \
		(SELECT SUM(amount/price) AS paid_kwh FROM accounts WHERE serial = $quoted_serial) - \
		(SELECT \
			(SELECT samples.energy FROM samples WHERE samples.serial = $quoted_serial ORDER BY samples.unix_time DESC LIMIT 1) - \
			(SELECT meters.last_energy FROM meters WHERE meters.serial = $quoted_serial) AS consumed_kwh \
		), 2) AS kwh_left]);
		$sth_kwh_left->execute;
		
		# get valve status from db
		$sth_valve_status = $dbh->prepare(qq[SELECT valve_status FROM meters WHERE serial = $quoted_serial]);
		$sth_valve_status->execute;
	
		if ($d_kwh_left = $sth_kwh_left->fetchrow_hashref) {
			#syslog('info', "\tkWh left: " . ($d_kwh_left->{kwh_left} - $d->{min_amount}));
			#if ($d_kwh_left->{kwh_left} < $d->{min_amount}) {
			if ($d_kwh_left->{kwh_left} < 0) {
				# close valve if not allready closed
				if ($d_valve_status = $sth_valve_status->fetchrow_hashref) {
					if ($d_valve_status->{valve_status} ne "close") {
						syslog('info', "\tsend mqtt retain for close and status to " . $d->{serial});
						$mqtt->retain('/config/v1/' . $d->{serial} . '/open' => '');
						$mqtt->retain('/config/v1/' . $d->{serial} . '/close' => 'retain');
						$mqtt->retain('/config/v1/' . $d->{serial} . '/status' => 'retain');
					}
				}
			}
			else {
				# open valve if not allready open
				if ($d_valve_status = $sth_valve_status->fetchrow_hashref) {
					if ($d_valve_status->{valve_status} ne "open") {
						syslog('info', "\tsend mqtt retain for open and status to " . $d->{serial});
						$mqtt->retain('/config/v1/' . $d->{serial} . '/close' => '');
						$mqtt->retain('/config/v1/' . $d->{serial} . '/open' => 'retain');
						$mqtt->retain('/config/v1/' . $d->{serial} . '/status' => 'retain');
					}
				}
			}
		}
	}
	sleep 1;
}

# end of main
