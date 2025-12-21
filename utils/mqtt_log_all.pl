#!/usr/bin/perl -w

use strict;
use Data::Dumper;
use Sys::Syslog;
use Net::MQTT::Simple;
use DBI;
use Crypt::Mode::CBC;
use Digest::SHA qw( sha256 hmac_sha256 );
use Config;

use lib qw( /home/meterlogger/perl );
use Nabovarme::Db;

STDOUT->autoflush(1);

openlog($0, "ndelay,pid", "local0");
syslog('info', "starting...");

my $protocol_version;
my $unix_time;
my $meter_serial;
my $sw_version;
my $valve_status;
my $uptime;
my $ssid;
my $rssi;
my $wifi_status;
my $ap_status;

my $mqtt;
$mqtt = Net::MQTT::Simple->new(q[mqtt]);
my $mqtt_data = undef;
#my $mqtt_count = 0;

# connect to db
my $dbh;
if ($dbh = Nabovarme::Db->my_connect) {
	$dbh->{'mysql_auto_reconnect'} = 1;
	syslog('info', "connected to db");
}
else {
	syslog('info', "cant't connect to db $!");
	die $!;
}

$SIG{HUP} = \&sig_handler;
$SIG{INT} = \&sig_handler;

# start mqtt run loop
$mqtt->run(	q[/#] => \&v2_mqtt_handler
);

# end of main

sub DESTROY {
	$dbh->disconnect();
	print "disconnected\n";
	exit;
}


sub sig_handler {
	$dbh->disconnect();
	print "disconnected\n";
	exit;
}

sub v2_mqtt_handler {
	my ($topic, $message) = @_;
	my $m;

	unless ($topic =~ m!/[^/]+/v(\d+)/([^/]+)/(\d+)!) {
		return;
	}
	$protocol_version = $1;
	$meter_serial = $2;
	$unix_time = $3;
	
	if ($ARGV[0]) {
		if ($meter_serial ne $ARGV[0]) {
			return;
		}
	}

	$message =~ /(.{32})(.{16})(.+)/s;
	my $mac = $1;
	my $iv = $2;
	my $ciphertext = $3;
		
	my $sth = $dbh->prepare(qq[SELECT `key` FROM meters WHERE serial = ] . $dbh->quote($meter_serial) . qq[ LIMIT 1]);
	$sth->execute;
	if ($sth->rows) {
		my $key = $sth->fetchrow_hashref->{key} || warn "no aes key found";
		my $sha256 = sha256(pack('H*', $key));
		my $aes_key = substr($sha256, 0, 16);
		my $hmac_sha256_key = substr($sha256, 16, 16);

		if ($mac eq hmac_sha256($topic . $iv . $ciphertext, $hmac_sha256_key)) {
			# hmac sha256 ok
			$m = Crypt::Mode::CBC->new('AES');
			$message = $m->decrypt($ciphertext, $aes_key, $iv);
			
#			$sth->finish;
			print $topic . "\t" . $message . "\n";
		}
		else {
			# hmac sha256 not ok

		}
	}
	$mqtt_data = undef;
}


__END__
