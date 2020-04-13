#!/usr/bin/perl -w

use strict;
use Data::Dumper;
use Sys::Syslog;
use Net::MQTT::Simple;
use DBI;
use Crypt::Mode::CBC;
use Digest::SHA qw( sha256 hmac_sha256 );
#use Time::HiRes qw( gettimeofday tv_interval );
use Config;

use lib qw( /etc/apache2/perl );
use lib qw( /opt/local/apache2/perl/ );
use Nabovarme::Db;
use Nabovarme::Crypto;

$SIG{INT} = \&sig_int_handler;

openlog($0, "ndelay,pid", "local0");
syslog('info', "starting...");

my $unix_time;
my $meter_serial;
my $sw_version;
my $valve_status;
my $uptime;
my $ssid;
my $rssi;
my $wifi_status;
my $ap_status;
my $reset_reason;

my $mqtt;
if ($Config{osname} =~ /darwin/) {
	$mqtt = Net::MQTT::Simple->new(q[10.8.0.84]);
}
else {
	$mqtt = Net::MQTT::Simple->new(q[127.0.0.1]);
}
my $mqtt_data = undef;
#my $mqtt_count = 0;

sub sig_int_handler {
	$mqtt->disconnect();
	die $!;
}
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

my $crypto = new Nabovarme::Crypto;

# start mqtt run loop
$mqtt->run(q[/sample/v2/#] => \&v2_mqtt_sample_handler);

# end of main


sub v2_mqtt_sample_handler {
	my ($topic, $message) = @_;
	my $m;

	unless ($topic =~ m!/sample/v\d+/([^/]+)/(\d+)!) {
		return;
	}	
	$meter_serial = $1;
	$unix_time = $2;

	$message = $crypto->decrypt_topic_message_for_serial($topic, $message, $meter_serial);
	if ($message) {	
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
		# save to db
		my $sth = $dbh->prepare(qq[INSERT INTO `samples` (
			`serial`,
			`heap`,
			`flow_temp`,
			`return_flow_temp`,
			`temp_diff`,
			`t3`,
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
			$dbh->quote($mqtt_data->{t3}) . ',' . 
			$dbh->quote($mqtt_data->{flow1}) . ',' . 
			$dbh->quote($mqtt_data->{effect1}) . ',' . 
			$dbh->quote($mqtt_data->{hr}) . ',' . 
			$dbh->quote($mqtt_data->{v1}) . ',' . 
			$dbh->quote($mqtt_data->{e1}) . ',' .
			$dbh->quote($unix_time) . qq[)]);
		$sth->execute || syslog('info', "can't log to db");
		$sth->finish;
		
		# update last_updated time stamp
		my $quoted_meter_serial = $dbh->quote($meter_serial);
		my $quoted_unix_time = $dbh->quote($unix_time);
		$dbh->do(qq[UPDATE meters SET \
						last_updated = $quoted_unix_time \
						WHERE serial = $quoted_meter_serial AND $quoted_unix_time > last_updated]) or warn $!;
		warn Dumper({uptime => $uptime});
		syslog('info', $topic . " " . $message);
		warn $topic . "\t" . $message;
	}
	else {
		# hmac sha256 not ok
	}
	$mqtt_data = undef;
#	print "*** " . tv_interval($t0) . " ***\n";
}


__END__
