#!/usr/bin/perl -w

use strict;
use Data::Dumper;
use Sys::Syslog;
use Net::MQTT::Simple;
use DBI;
use Crypt::Mode::CBC;

use lib qw( /etc/apache2/perl );
#use lib qw( /opt/local/apache2/perl/ );
use Nabovarme::Db;

use constant AES_KEY => '2b7e151628aed2a6abf7158809cf4f3c';

openlog($0, "ndelay,pid", "local0");
syslog('info', "starting...");

my $protocol_version;
my $unix_time;
my $meter_serial;
my $sw_version;
my $valve_status;
my $uptime;

my $mqtt = Net::MQTT::Simple->new(q[localhost]);
#my $mqtt = Net::MQTT::Simple->new(q[10.8.0.84]);
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

# start mqtt run loop
$mqtt->run(	q[/sample/#] => \&sample_mqtt_handler,
	q[/version/v1/#] => \&mqtt_version_handler,
	q[/status/v1/#] => \&mqtt_status_handler,
	q[/uptime/v1/#] => \&mqtt_uptime_handler
);

# end of main

sub mqtt_version_handler {
	my ($topic, $message) = @_;
	unless ($topic =~ m!/version/v1/(\d+)/(\d+)!) {
		return;
	}
	$sw_version = $message;
	$meter_serial = $1;
	$unix_time = $2;
	
	my $quoted_sw_version = $dbh->quote($sw_version);
	my $quoted_meter_serial = $dbh->quote($meter_serial);
	my $quoted_unix_time = $dbh->quote($unix_time);
	$dbh->do(qq[UPDATE meters SET \
					sw_version = $quoted_sw_version, \
					last_updated = $quoted_unix_time \
					WHERE serial = $quoted_meter_serial]) or warn $!;
	warn Dumper({sw_version => $sw_version});
}

sub mqtt_status_handler {
	my ($topic, $message) = @_;
	unless ($topic =~ m!/status/v1/(\d+)/(\d+)!) {
		return;
	}
	$valve_status = $message;
	$meter_serial = $1;
	$unix_time = $2;

	my $quoted_valve_status = $dbh->quote($valve_status);
	my $quoted_meter_serial = $dbh->quote($meter_serial);
	my $quoted_unix_time = $dbh->quote($unix_time);
	$dbh->do(qq[UPDATE meters SET \
					valve_status = $quoted_valve_status, \
					last_updated = $quoted_unix_time \
					WHERE serial = $quoted_meter_serial]) or warn $!;
	warn Dumper({sw_version => $valve_status});
}

sub mqtt_uptime_handler {
	my ($topic, $message) = @_;
	unless ($topic =~ m!/uptime/v1/(\d+)/(\d+)!) {
		return;
	}
	$uptime = $message;
	$meter_serial = $1;
	$unix_time = $2;
	
	my $quoted_uptime = $dbh->quote($uptime);
	my $quoted_meter_serial = $dbh->quote($meter_serial);
	my $quoted_unix_time = $dbh->quote($unix_time);
	$dbh->do(qq[UPDATE meters SET \
					uptime = $quoted_uptime, \
					last_updated = $quoted_unix_time \
					WHERE serial = $quoted_meter_serial]) or warn $!;
	warn Dumper({sw_version => $sw_version});
}

sub sample_mqtt_handler {
	my ($topic, $message) = @_;

	unless ($topic =~ m!/sample/v(\d+)/(\d+)/(\d+)!) {
		return;
	}
	$protocol_version = $1;
	$meter_serial = $2;
	$unix_time = $3;
	
	if ($protocol_version == 2) {
		# encrypted message
		my $iv;
		my $ciphertext;
		my $m;
		
		$message =~ /([\da-f]{32})([\da-f]+)/i;
		$iv = pack 'H*', $1;
		$ciphertext = pack 'H*', $2;
		$m = Crypt::Mode::CBC->new('AES');
		$message = $m->decrypt($ciphertext, pack('H*', AES_KEY), $iv);
	}
	
	# parse message
	$message =~ s/&$//;
	
	my ($key, $value, $unit);
	my @key_value_list = split(/&/, $message);
	my $key_value; 
	foreach $key_value (@key_value_list) {
		if (($key, $value, $unit) = $key_value =~ /([^=]*)=(\S+)(?:\s+(.*))?/) {
			# check energy register unit
			if ($key =~ /^e1$/i) {
				if ($unit =~ /^MWh$/i) {
					$value *= 1000;
					$unit = 'kWh';
				}
			}
			$mqtt_data->{$key} = $value;
		}
	}
	warn Dumper($mqtt_data);
	
	# save to db
	if ($unix_time < time() + 7200) {
		my $sth = $dbh->prepare(qq[INSERT INTO `samples` (
			`serial`,
			`heap`,
			`flow_temp`,
			`return_flow_temp`,
			`temp_diff`,
			`flow`,
			`effect`,
			`hours`,
			`volume`,
			`energy`,
			`unix_time`
			) VALUES (] . 
			$dbh->quote($meter_serial) . ',' . 
			$dbh->quote($mqtt_data->{heap}) . ',' . 
			$dbh->quote($mqtt_data->{t1}) . ',' . 
			$dbh->quote($mqtt_data->{t2}) . ',' . 
			$dbh->quote($mqtt_data->{tdif}) . ',' . 
			$dbh->quote($mqtt_data->{flow1}) . ',' . 
			$dbh->quote($mqtt_data->{effect1}) . ',' . 
			$dbh->quote($mqtt_data->{hr}) . ',' . 
			$dbh->quote($mqtt_data->{v1}) . ',' . 
			$dbh->quote($mqtt_data->{e1}) . ',' .
			$dbh->quote($unix_time) . qq[)]);
		$sth->execute || syslog('info', "can't log to db");
		$sth->finish;
	}
	$mqtt_data = undef;
}

