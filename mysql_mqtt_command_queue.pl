#!/usr/bin/perl -w

use strict;
use Data::Dumper;
use Sys::Syslog;
use Net::MQTT::Simple;
use DBI;
use Crypt::Mode::CBC;
use Digest::SHA qw( sha256 hmac_sha256 );
use Config;
use Proc::Pidfile;
use threads;
use threads::shared;

use lib qw( /etc/apache2/perl );
use lib qw( /opt/local/apache2/perl );
use lib qw( /Users/loppen/Documents/stoffer/MeterLoggerWeb/perl );
use Nabovarme::Db;

use constant CONFIG_FILE => qw (/etc/Nabovarme.conf );

my $config = new Config::Simple(CONFIG_FILE) || die $!;
my $mqtt_host :shared = $config->param('mqtt_host');
my $mqtt_port :shared = $config->param('mqtt_port');

$SIG{INT} = \&sig_int_handler;

my %serials_watched :shared = ();
my %mqtt_functions_watched :shared = ();

my $pp = Proc::Pidfile->new();

#print Dumper $pp->pidfile();

openlog($0, "ndelay,pid", "local0");
syslog('info', "starting...");


sub sig_int_handler {

	die $!;
}

sub mqtt_handler {
	my ($topic, $message) = @_;
	
	my $dbh;
	my $sth;
	my $d;

	unless ($topic =~ m!/[^/]+/v2/([^/]+)/(\d+)!) {
		return;
	}
	
	my $meter_serial = $1;
	my $unix_time = $2;

	# only react to meters we have sent a mqtt function to
	unless (grep(/$meter_serial/, keys %serials_watched)) {
		return;
	}
	
	$message =~ /(.{32})(.{16})(.+)/s;
	my $mac = $1;
	my $iv = $2;
	my $ciphertext = $3;
	
	# connect to db
	if ($dbh = Nabovarme::Db->my_connect) {
		$dbh->{'mysql_auto_reconnect'} = 1;
		syslog('info', "connected to db");
	}
	else {
		syslog('info', "cant't connect to db $!");
		die $!;
	}

	$sth = $dbh->prepare(qq[SELECT `key`, `sw_version` FROM meters WHERE serial = ] . $dbh->quote($meter_serial) . qq[ LIMIT 1]);
	$sth->execute;
	if ($sth->rows) {
		$_ = $sth->fetchrow_hashref;
		my $key = $_->{key} || warn "no aes key found\n";
		
		# only for sw version higher than or equal to build #923
		$_->{sw_version} =~ /[^-]+-(\d+)/;
		if ($1 < 923) {
			return;
		}
		
		my $sha256 = sha256(pack('H*', $key));
		my $aes_key = substr($sha256, 0, 16);
		my $hmac_sha256_key = substr($sha256, 16, 16);
		
		if ($mac eq hmac_sha256($topic . $iv . $ciphertext, $hmac_sha256_key)) {
			# hmac sha256 ok
			my $m = Crypt::Mode::CBC->new('AES');
			my $cleartext = $m->decrypt($ciphertext, $aes_key, $iv);

			# only react to functions we have sent a mqtt function for
			my ($function) = $topic =~ m!/([^/]+)!;
			unless (grep(/$function/, keys %mqtt_functions_watched)) {
				return;
			}

			if ($function =~ /^open_until/i) {
				warn "received mqtt reply from $meter_serial: $function, with param: $cleartext, deleting from mysql queue\n";
				syslog('info', "received mqtt reply from $meter_serial: $function, with param: $cleartext, deleting from mysql queue");
				# do mysql stuff here
				$dbh->do(qq[DELETE FROM command_queue2 WHERE `serial` = ] . $dbh->quote($meter_serial) . qq[ AND `function` LIKE ] . $dbh->quote($function)) or warn $!;
			}
			else {
				warn "received mqtt reply from $meter_serial: $function, with param: $cleartext, activate callback\n";
				syslog('info', "received mqtt reply from $meter_serial: $function, with param: $cleartext activate callback");
				$dbh->do(qq[UPDATE command_queue2 SET \
					`state` = 'received', \
				    `param` = ] . $dbh->quote($cleartext) . qq[ 
					WHERE `serial` = ] . $dbh->quote($meter_serial) . qq[ \
					AND `function` LIKE ] . $dbh->quote($function)) or warn $!;
			}
		}
		else {
			# hmac sha256 not ok
			warn "serial $meter_serial checksum error\n";  
			syslog('info', "serial $meter_serial checksum error");     
		}
	}
}

sub publish_thread {
	my $dbh;
	my $sth;
	my $d;
	
	my $publish_mqtt = Net::MQTT::Simple->new($mqtt_host . ':' . $mqtt_port);
	
	# connect to db
	if ($dbh = Nabovarme::Db->my_connect) {
		$dbh->{'mysql_auto_reconnect'} = 1;
		warn "connected to db\n";
		syslog('info', "connected to db");
	}
	else {
		syslog('info', "cant't connect to db $!");
		warn "cant't connect to db $!\n";
		die $!;
	}

	my $m = Crypt::Mode::CBC->new('AES');
 	while (1) {
		$sth = $dbh->prepare(qq[SELECT command_queue2.`serial`, command_queue2.`function`, command_queue2.`param`, meters.`key` \
			FROM command_queue2, meters \
			WHERE FROM_UNIXTIME(`unix_time`) <= NOW() AND command_queue2.`serial` LIKE meters.`serial` \
		]);
		$sth->execute;
		while ($d = $sth->fetchrow_hashref) {
			# add to list of serial and function being watched for
			$serials_watched{$d->{serial}} = 1;
			$mqtt_functions_watched{$d->{function}} = 1;
			
			# send mqtt function to meter
			my $key = $d->{key};
			my $sha256 = sha256(pack('H*', $key));
			my $aes_key = substr($sha256, 0, 16);
			my $hmac_sha256_key = substr($sha256, 16, 16);
			warn "send mqtt function " . $d->{function} . " to " . $d->{serial} . "\n";
			syslog('info', "send mqtt function " . $d->{function} . " to " . $d->{serial});
			my $topic = '/config/v2/' . $d->{serial} . '/' . time() . '/' . $d->{function};
			my $message = $d->{param};
			my $iv = join('', map(chr(int rand(256)), 1..16));
			$message = $m->encrypt($message, $aes_key, $iv);
			$message = $iv . $message;
			my $hmac_sha256_hash = hmac_sha256($topic . $message, $hmac_sha256_key);
			
			$publish_mqtt->publish($topic => $hmac_sha256_hash . $message);
		} 	        
		sleep 1;
	}               
}

sub subscribe_thread {
	my $subscribe_mqtt = Net::MQTT::Simple->new($mqtt_host . ':' . $mqtt_port);
	
	$subscribe_mqtt->run(q[/#], \&mqtt_handler);
}

my $publish_thr = threads->create(\&publish_thread);
my $subscribe_thr = threads->create(\&subscribe_thread);
$publish_thr->detach();
$subscribe_thr->detach();

while (1) {
	sleep 1;
}

1;

__END__
