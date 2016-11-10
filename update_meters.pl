#!/usr/bin/perl -w

use strict;
use Data::Dumper;
use Sys::Syslog;
use Net::MQTT::Simple;
use DBI;
use Crypt::Mode::CBC;
use Math::Random::Secure qw(rand);
use Digest::SHA qw( sha256 hmac_sha256 );
use Config;
use Proc::Pidfile;

use lib qw( /etc/apache2/perl );
use lib qw( /opt/local/apache2/perl/ );
use Nabovarme::Db;

$SIG{HUP} = \&get_version_and_status;

$SIG{INT} = \&sig_int_handler;

my $pp = Proc::Pidfile->new();
print Dumper $pp->pidfile();

openlog($0, "ndelay,pid", "local0");
syslog('info', "starting...");

my $unix_time;
my $meter_serial;
my $mqtt_data = undef;
#my $mqtt_count = 0;

my $dbh;
my $sth;
my $sth_kwh_left;
my $sth_valve_status;
my $d;
my $d_kwh_left;
my $d_valve_status;

my $key;
my $m = Crypt::Mode::CBC->new('AES');
my $sha256;
my $aes_key;
my $hmac_sha256_key;
my $hmac_sha256_hash;
my $iv;
my $topic;
my $message;

my $mqtt;
if ($Config{osname} =~ /darwin/) {
	$mqtt = Net::MQTT::Simple->new(q[10.8.0.84]);
}
else {
	$mqtt = Net::MQTT::Simple->new(q[127.0.0.1]);
}

# connect to db
if ($dbh = Nabovarme::Db->my_connect) {
	$dbh->{'mysql_auto_reconnect'} = 1;
	syslog('info', "connected to db");
}
else {
	syslog('info', "cant't connect to db $!");
	die $!;
}

get_version_and_status();
while (1) {
	# open or close valve according to payment status
	$sth = $dbh->prepare(qq[SELECT `serial`, `info`, `min_amount`, `valve_status`, `sw_version`, `key` FROM meters WHERE `serial` IN (SELECT DISTINCT(`serial`) `serial` FROM samples) AND `key` is not NULL]);
	$sth->execute;
	
	while ($d = $sth->fetchrow_hashref) {
		if ($d->{sw_version} =~ /THERMO/) {
			# update all meters containing THERMO in version string
			my $quoted_serial = $dbh->quote($d->{serial});
			#syslog('info', "serial #" . $d->{serial});
			print Dumper $d->{valve_status};
			
			# get kWh left from db
			$sth_kwh_left = $dbh->prepare(qq[SELECT ROUND( \
			(SELECT SUM(amount/price) AS paid_kwh FROM accounts WHERE serial = $quoted_serial) - \
			(SELECT \
				(SELECT samples.energy FROM samples WHERE samples.serial = $quoted_serial ORDER BY samples.unix_time DESC LIMIT 1) - \
				(SELECT meters.last_energy FROM meters WHERE meters.serial = $quoted_serial) AS consumed_kwh \
			), 2) AS kwh_left]);
			$sth_kwh_left->execute;
			
			if ($d_kwh_left = $sth_kwh_left->fetchrow_hashref) {
				#syslog('info', "\tkWh left: " . ($d_kwh_left->{kwh_left} - $d->{min_amount}));
				print Dumper("serial: " . $d->{serial} . "\tkWh left: " . ($d_kwh_left->{kwh_left} - $d->{min_amount}) . " status: " . $d->{valve_status});
				#if ($d_kwh_left->{kwh_left} < $d->{min_amount}) {
	
				$key = $d->{key};
				$sha256 = sha256(pack('H*', $key));
				$aes_key = substr($sha256, 0, 16);
				$hmac_sha256_key = substr($sha256, 16, 16);
				
				if ($d_kwh_left->{kwh_left} <= 0) {
					# close valve if not allready closed
					if ($d->{valve_status} !~ /close/i) {
						printf("valve status: " . $d->{valve_status} . "\n");
						# send close
						printf("send close\n");
						syslog('info', "\tsend mqtt retain for close and status to " . $d->{serial});
						$topic = '/config/v2/' . $d->{serial} . '/close';
						$message = '';
						$iv = join('', map(chr(int rand(256)), 1..16));
						$message = $m->encrypt($message, $aes_key, $iv);
						$message = $iv . $message;
						$hmac_sha256_hash = hmac_sha256($topic . $message, $hmac_sha256_key);
						$mqtt->publish($topic => $hmac_sha256_hash . $message);
						
						# send status
						$topic = '/config/v2/' . $d->{serial} . '/status';
						$message = '';
						$iv = join('', map(chr(int rand(256)), 1..16));
						$message = $m->encrypt($message, $aes_key, $iv);
						$message = $iv . $message;
						$hmac_sha256_hash = hmac_sha256($topic . $message, $hmac_sha256_key);
						$mqtt->publish($topic => $hmac_sha256_hash . $message);
					}
				}
				else {
					# open valve if not allready open
					if ($d->{valve_status} !~ /open/i) {
						printf("valve status: " . $d->{valve_status} . "\n");
						syslog('info', "\tsend mqtt retain for open and status to " . $d->{serial});
						# send open
						printf("send open\n");
						syslog('info', "\tsend mqtt retain for close and status to " . $d->{serial});
						$topic = '/config/v2/' . $d->{serial} . '/open';
						$message = '';
						$iv = join('', map(chr(int rand(256)), 1..16));
						$message = $m->encrypt($message, $aes_key, $iv);
						$message = $iv . $message;
						$hmac_sha256_hash = hmac_sha256($topic . $message, $hmac_sha256_key);
						$mqtt->publish($topic => $hmac_sha256_hash . $message);
						
						# send status
						$topic = '/config/v2/' . $d->{serial} . '/status';
						$message = '';
						$iv = join('', map(chr(int rand(256)), 1..16));
						$message = $m->encrypt($message, $aes_key, $iv);
						$message = $iv . $message;
						$hmac_sha256_hash = hmac_sha256($topic . $message, $hmac_sha256_key);
						$mqtt->publish($topic => $hmac_sha256_hash . $message);
					}
				}
	
			}
		}
	}
	sleep 1;
}

# end of main

sub get_version_and_status {
	$sth = $dbh->prepare(qq[SELECT `serial`, `key` FROM meters WHERE `serial` IN (SELECT DISTINCT(`serial`) `serial` FROM samples) AND `key` is not NULL]);
	$sth->execute;
	
	syslog('info', "send mqtt retain to all meters for version and status");
	while ($d = $sth->fetchrow_hashref) {
		my $quoted_serial = $dbh->quote($d->{serial});

		$key = $d->{key};
		$sha256 = sha256(pack('H*', $key));
		$aes_key = substr($sha256, 0, 16);
		$hmac_sha256_key = substr($sha256, 16, 16);
		
		syslog('info', "\tsend mqtt version, status and uptime commands to " . $d->{serial});
		# send version
		$topic = '/config/v2/' . $d->{serial} . '/version';
		$message = '';
		$iv = join('', map(chr(int rand(256)), 1..16));
		$message = $m->encrypt($message, $aes_key, $iv);
		$message = $iv . $message;
		$hmac_sha256_hash = hmac_sha256($topic . $message, $hmac_sha256_key);
		$mqtt->publish($topic => $hmac_sha256_hash . $message);

		# send status
		$topic = '/config/v2/' . $d->{serial} . '/status';
		$message = '';
		$iv = join('', map(chr(int rand(256)), 1..16));
		$message = $m->encrypt($message, $aes_key, $iv);
		$message = $iv . $message;
		$hmac_sha256_hash = hmac_sha256($topic . $message, $hmac_sha256_key);
		$mqtt->publish($topic => $hmac_sha256_hash . $message);

		# send uptime
		$topic = '/config/v2/' . $d->{serial} . '/uptime';
		$message = '';
		$iv = join('', map(chr(int rand(256)), 1..16));
		$message = $m->encrypt($message, $aes_key, $iv);
		$message = $iv . $message;
		$hmac_sha256_hash = hmac_sha256($topic . $message, $hmac_sha256_key);
		$mqtt->publish($topic => $hmac_sha256_hash . $message);

		# send ssid
		$topic = '/config/v2/' . $d->{serial} . '/ssid';
		$message = '';
		$iv = join('', map(chr(int rand(256)), 1..16));
		$message = $m->encrypt($message, $aes_key, $iv);
		$message = $iv . $message;
		$hmac_sha256_hash = hmac_sha256($topic . $message, $hmac_sha256_key);
		$mqtt->publish($topic => $hmac_sha256_hash . $message);

		# send rssi
		$topic = '/config/v2/' . $d->{serial} . '/rssi';
		$message = '';
		$iv = join('', map(chr(int rand(256)), 1..16));
		$message = $m->encrypt($message, $aes_key, $iv);
		$message = $iv . $message;
		$hmac_sha256_hash = hmac_sha256($topic . $message, $hmac_sha256_key);
		$mqtt->publish($topic => $hmac_sha256_hash . $message);
	}
}

sub sig_int_handler {

	die $!;
}

1;
__END__