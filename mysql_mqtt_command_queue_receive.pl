#!/usr/bin/perl -w

use strict;
use Data::Dumper;
use Sys::Syslog;
use Net::MQTT::Simple;
use DBI;
use Crypt::Mode::CBC;
use Digest::SHA qw( sha256 hmac_sha256 );
use Config;
use Time::HiRes qw( gettimeofday tv_interval );

use lib qw( /etc/apache2/perl );
use lib qw( /opt/local/apache2/perl );
use lib qw( /Users/loppen/Documents/stoffer/MeterLoggerWeb/perl );
use lib qw( /Users/stoffer/src/esp8266/MeterLoggerWeb/perl );
use Nabovarme::Db;

use constant CONFIG_FILE => qw (/etc/Nabovarme.conf );

my $config = new Config::Simple(CONFIG_FILE) || die $!;
my $mqtt_host = $config->param('mqtt_host');
my $mqtt_port = $config->param('mqtt_port');

my $config_cached_time = $config->param('cached_time') || 3600;	# default 1 hour

$SIG{INT} = \&sig_int_handler;

my $dbh;
my $sth;
my $d;

my $key_cache;

openlog($0, "ndelay,pid", "local0");
syslog('info', "starting...");


sub sig_int_handler {

	die $!;
}

sub mqtt_handler {
	my ($topic, $message) = @_;
	
	my $t0 = [gettimeofday()];
	my $sw_version;
	unless ($topic =~ m!/[^/]+/v2/([^/]+)/(\d+)!) {
		return;
	}
	
	my $meter_serial = $1;
	my $unix_time = $2;

	# only react to meters we have sent a mqtt function to
	$sth = $dbh->prepare(qq[SELECT `serial` FROM command_queue WHERE serial = ] . $dbh->quote($meter_serial) . qq[ LIMIT 1]);
	$sth->execute;
	unless ($sth->rows) {
		return;
	}
#	print Dumper tv_interval($t0);
	
	$message =~ /(.{32})(.{16})(.+)/s;

	my $key = '';
	my $mac = $1;
	my $iv = $2;
	my $ciphertext = $3;

	my ($function) = $topic =~ m!/([^/]+)!;
	if ($function =~ /^config$/i) {
		return;
	}

	if (exists($key_cache->{$meter_serial}) && ($key_cache->{$meter_serial}->{cached_time} > (time() - $config_cached_time))) {
		$key = $key_cache->{$meter_serial}->{key};
	}
	else {
		$sth = $dbh->prepare(qq[SELECT `key` FROM meters WHERE serial = ] . $dbh->quote($meter_serial) . qq[ LIMIT 1]);
		$sth->execute;
		if ($sth->rows) {
			$d = $sth->fetchrow_hashref;
			$key_cache->{$meter_serial}->{key} = $d->{key};
			$key_cache->{$meter_serial}->{cached_time} = time();

			$key = $d->{key} || warn "no aes key found\n";
		}
	}

	if ($key) {
		# handle special case
		if ($function =~ /^scan_result$/i) {
			warn "received mqtt reply from $meter_serial: $function, deleting from mysql queue\n";
			syslog('info', "received mqtt reply from $meter_serial: $function, deleting from mysql queue");
			# do mysql stuff here
			$dbh->do(qq[DELETE FROM command_queue WHERE `serial` = ] . $dbh->quote($meter_serial) . qq[ AND `function` LIKE 'scan']) or warn $!;
			return;
		}
		
		my $sha256 = sha256(pack('H*', $key));
		my $aes_key = substr($sha256, 0, 16);
		my $hmac_sha256_key = substr($sha256, 16, 16);
		
		if ($mac eq hmac_sha256($topic . $iv . $ciphertext, $hmac_sha256_key)) {
			# hmac sha256 ok
			my $m = Crypt::Mode::CBC->new('AES');
			my $cleartext = $m->decrypt($ciphertext, $aes_key, $iv);
			# remove trailing nulls
			$cleartext =~ s/[\x00\s]+$//;
			$cleartext .= '';

			# only react to functions we have sent a mqtt function for
			$sth = $dbh->prepare(qq[SELECT `serial` FROM command_queue WHERE serial = ] . $dbh->quote($meter_serial) . qq[ AND `function` LIKE ] . $dbh->quote($function) . qq[ LIMIT 1]);
			$sth->execute;
			unless ($sth->rows) {
				return;
			}
			
			# handle special case
			if ($function =~ /^open_until/i) {
				# do mysql stuff here
				# if open_until parameter matches the one sent to meter
				$sth = $dbh->prepare(qq[SELECT `serial` FROM command_queue \
					WHERE serial = ] . $dbh->quote($meter_serial) . qq[ \
					AND `function` LIKE ] . $dbh->quote($function) . qq[ \
					AND `param` > ] . ($cleartext - 1) . qq[ \
					AND `param` < ] . ($cleartext + 1) . qq[ \
					LIMIT 1]);
				$sth->execute;
				if ($sth->rows) {
					warn "received mqtt reply from $meter_serial: $function, param: $cleartext, deleting from mysql queue\n";
					syslog('info', "received mqtt reply from $meter_serial: $function, param: $cleartext, deleting from mysql queue");
					$dbh->do(qq[DELETE FROM command_queue WHERE `serial` = ] . $dbh->quote($meter_serial) . qq[ \
						AND `function` LIKE ] . $dbh->quote($function) . qq[\ 
						AND `param` <= ] . ($cleartext + 1)) or warn $!;
				}
				else {
					warn "received mqtt reply from $meter_serial: $function, param: $cleartext not matching queue value\n";
					syslog('info', "received mqtt reply from $meter_serial: $function, param: $cleartext not matching queue value");
				}
				return;
			}
			if ($function =~ /^status$/i) {
				warn "received mqtt reply from $meter_serial: $function, deleting from mysql queue\n";
				syslog('info', "received mqtt reply from $meter_serial: $function, deleting from mysql queue");
				# do mysql stuff here
				$dbh->do(qq[DELETE FROM command_queue WHERE `serial` = ] . $dbh->quote($meter_serial) . qq[ \
					AND `function` LIKE ] . $dbh->quote($function)) or warn $!;
				return;
			}

			# handle general case
#			$sth = $dbh->prepare(qq[SELECT `serial` FROM command_queue WHERE serial = ] . $dbh->quote($meter_serial) . qq[ AND `function` LIKE ] . $dbh->quote($function) . qq[ LIMIT 1]);

			# mark it for deletion
			$sth = $dbh->prepare(qq[SELECT `id`, `has_callback` FROM command_queue \
				WHERE `serial` = ] . $dbh->quote($meter_serial) . qq[ AND `function` LIKE ] . $dbh->quote($function) . qq[ AND `state` = 'sent']);
			$sth->execute;
			if ($d = $sth->fetchrow_hashref) {
				if ($d->{has_callback}) {
					warn "mark serial $meter_serial, command $function for deletion\n";
					syslog('info', "mark serial $meter_serial, command $function for deletion");
					$dbh->do(qq[UPDATE command_queue SET \
						`state` = 'received', \
					    `param` = ] . $dbh->quote($cleartext) . qq[ \
						WHERE `id` = ] . $d->{id}) or warn $!;
				}
				else {
					# delete if has_callback not set
					warn "deleting serial $meter_serial, command $function from mysql queue\n";
					syslog('info', "deleting serial $meter_serial, command $function from mysql queue");
#					$dbh->do(qq[DELETE FROM command_queue WHERE `id` = ] . $d->{id});
					$dbh->do(qq[DELETE FROM command_queue WHERE `serial` = ] . $dbh->quote($meter_serial) . qq[ AND `function` LIKE ] . $dbh->quote($function) . qq[ AND `state` = 'sent']);
				}
			}
		}
		else {
			# hmac sha256 not ok
			warn "serial $meter_serial checksum error\n";  
			syslog('info', "serial $meter_serial checksum error");     
		}
	}
}

# connect to db
if ($dbh = Nabovarme::Db->my_connect) {
	$dbh->{'mysql_auto_reconnect'} = 1;
}
else {
	syslog('info', "cant't connect to db $!");
	die $!;
}

my $subscribe_mqtt = Net::MQTT::Simple->new($mqtt_host . ':' . $mqtt_port);
$subscribe_mqtt->subscribe(q[/cron/#], \&mqtt_handler);
$subscribe_mqtt->subscribe(q[/ping/#], \&mqtt_handler);
$subscribe_mqtt->subscribe(q[/version/#], \&mqtt_handler);
$subscribe_mqtt->subscribe(q[/status/#], \&mqtt_handler);
$subscribe_mqtt->subscribe(q[/open_until/#], \&mqtt_handler);
$subscribe_mqtt->subscribe(q[/open_until_delta/#], \&mqtt_handler);
$subscribe_mqtt->subscribe(q[/uptime/#], \&mqtt_handler);
$subscribe_mqtt->subscribe(q[/stack_trace/#], \&mqtt_handler);
$subscribe_mqtt->subscribe(q[/vdd/#], \&mqtt_handler);
$subscribe_mqtt->subscribe(q[/rssi/#], \&mqtt_handler);
$subscribe_mqtt->subscribe(q[/ssid/#], \&mqtt_handler);
$subscribe_mqtt->subscribe(q[/set_ssid/#], \&mqtt_handler);
$subscribe_mqtt->subscribe(q[/set_pwd/#], \&mqtt_handler);
$subscribe_mqtt->subscribe(q[/set_ssid_pwd/#], \&mqtt_handler);
$subscribe_mqtt->subscribe(q[/scan_result/#], \&mqtt_handler);
$subscribe_mqtt->subscribe(q[/wifi_status/#], \&mqtt_handler);
$subscribe_mqtt->subscribe(q[/ap_status/#], \&mqtt_handler);
$subscribe_mqtt->subscribe(q[/save/#], \&mqtt_handler);
$subscribe_mqtt->subscribe(q[/mem/#], \&mqtt_handler);
$subscribe_mqtt->subscribe(q[/reset_reason/#], \&mqtt_handler);
$subscribe_mqtt->run();

1;

__END__
