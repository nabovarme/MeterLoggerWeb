#!/usr/bin/perl -w

use strict;
use Data::Dumper;
use Net::MQTT::Simple;
use DBI;
use Crypt::Mode::CBC;
use Digest::SHA qw( sha256 hmac_sha256 );
use Config::Simple;

use lib qw( /etc/apache2/perl );
use lib qw( /opt/local/apache2/perl/ );
use Nabovarme::Db;

use constant CONFIG_FILE => qw (/etc/Nabovarme.conf );

my $config = new Config::Simple(CONFIG_FILE) || die $!;

warn("starting...\n");

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
my $reset_reason;

my $mqtt = Net::MQTT::Simple->new($config->param('mqtt_host'));

my $mqtt_data = undef;
#my $mqtt_count = 0;

# connect to db
my $dbh;
if ($dbh = Nabovarme::Db->my_connect) {
	$dbh->{'mysql_auto_reconnect'} = 1;
	warn("connected to db\n");
}
else {
	warn("cant't connect to db $!\n");
	die $!;
}

# start mqtt run loop
$mqtt->run(	q[/sample/v2/#] => \&v2_mqtt_sample_handler,
	q[/version/v2/#] => \&v2_mqtt_version_handler,
	q[/status/v2/#] => \&v2_mqtt_status_handler,
	q[/uptime/v2/#] => \&v2_mqtt_uptime_handler,
	q[/ssid/v2/#] => \&v2_mqtt_ssid_handler,
	q[/rssi/v2/#] => \&v2_mqtt_rssi_handler,
	q[/wifi_status/v2/#] => \&v2_mqtt_wifi_status_handler,
	q[/ap_status/v2/#] => \&v2_mqtt_ap_status_handler,
	q[/reset_reason/v2/#] => \&v2_mqtt_reset_reason_handler,
	q[/scan_result/v2/#] => \&v2_mqtt_scan_result_handler,
	q[/crypto/v2/#] => \&v2_mqtt_crypto_test_handler
);

# end of main


sub v2_mqtt_version_handler {
	my ($topic, $message) = @_;
	my $m;

	unless ($topic =~ m!/version/v\d+/([^/]+)/(\d+)!) {
	        return;
	}
	$meter_serial = $1;
	$unix_time = $2;

	$message =~ /(.{32})(.{16})(.+)/s;
	my $mac = $1;
	my $iv = $2;
	my $ciphertext = $3;
		
	my $sth = $dbh->prepare(qq[SELECT `key` FROM meters WHERE serial = ] . $dbh->quote($meter_serial) . qq[ LIMIT 1]);
	$sth->execute;
	if ($sth->rows) {
		my $key = $sth->fetchrow_hashref->{key} || warn "no aes key found\n";
		my $sha256 = sha256(pack('H*', $key));
		my $aes_key = substr($sha256, 0, 16);
		my $hmac_sha256_key = substr($sha256, 16, 16);

		if ($mac eq hmac_sha256($topic . $iv . $ciphertext, $hmac_sha256_key)) {
			# hmac sha256 ok
			$m = Crypt::Mode::CBC->new('AES');
			$sw_version = $m->decrypt($ciphertext, $aes_key, $iv);

			# remove trailing nulls
			$sw_version =~ s/[\x00\s]+$//;
			$sw_version .= '';

			my $quoted_sw_version = $dbh->quote($sw_version);
			my $quoted_meter_serial = $dbh->quote($meter_serial);
			my $quoted_unix_time = $dbh->quote($unix_time);
			$dbh->do(qq[UPDATE meters SET \
							sw_version = $quoted_sw_version, \
							last_updated = $quoted_unix_time \
							WHERE serial = $quoted_meter_serial AND $quoted_unix_time > last_updated]) or warn "$!\n";
			warn $topic . "\t" . $sw_version . "\n";
		}
		else {
			# hmac sha256 not ok
			warn($topic . "hmac error\n");
			warn $topic . "\t" . unpack('H*', $message) . "\n";
		}
	}
}

sub v2_mqtt_status_handler {
	my ($topic, $message) = @_;
	my $m;
	
	unless ($topic =~ m!/status/v\d+/([^/]+)/(\d+)!) {
		return;
	}
	$meter_serial = $1;
	$unix_time = $2;

	$message =~ /(.{32})(.{16})(.+)/s;
	my $mac = $1;
	my $iv = $2;
	my $ciphertext = $3;
		
	my $sth = $dbh->prepare(qq[SELECT `key` FROM meters WHERE serial = ] . $dbh->quote($meter_serial) . qq[ LIMIT 1]);
	$sth->execute;
	if ($sth->rows) {
		my $key = $sth->fetchrow_hashref->{key} || warn "no aes key found\n";
		my $sha256 = sha256(pack('H*', $key));
		my $aes_key = substr($sha256, 0, 16);
		my $hmac_sha256_key = substr($sha256, 16, 16);

		if ($mac eq hmac_sha256($topic . $iv . $ciphertext, $hmac_sha256_key)) {
			# hmac sha256 ok
			$m = Crypt::Mode::CBC->new('AES');
			$valve_status = $m->decrypt($ciphertext, $aes_key, $iv);
			
			# remove trailing nulls
			$valve_status =~ s/[\x00\s]+$//;
			$valve_status .= '';

			my $quoted_valve_status = $dbh->quote($valve_status);
			my $quoted_meter_serial = $dbh->quote($meter_serial);
			my $quoted_unix_time = $dbh->quote($unix_time);
			$dbh->do(qq[UPDATE meters SET \
							valve_status = $quoted_valve_status, \
							last_updated = $quoted_unix_time \
							WHERE serial = $quoted_meter_serial AND $quoted_unix_time > last_updated]) or warn "$!\n";
			warn $topic . "\t" . $valve_status . "\n";			
		}
		else {
			# hmac sha256 not ok
			warn("serial $meter_serial checksum error\n");
		}
	}
}

sub v2_mqtt_uptime_handler {
	my ($topic, $message) = @_;
	my $m;
	
	unless ($topic =~ m!/uptime/v\d+/([^/]+)/(\d+)!) {
		return;
	}
	$meter_serial = $1;
	$unix_time = $2;
	
	$message =~ /(.{32})(.{16})(.+)/s;
	my $mac = $1;
	my $iv = $2;
	my $ciphertext = $3;
		
	my $sth = $dbh->prepare(qq[SELECT `key` FROM meters WHERE serial = ] . $dbh->quote($meter_serial) . qq[ LIMIT 1]);
	$sth->execute;
	if ($sth->rows) {
		my $key = $sth->fetchrow_hashref->{key} || warn "no aes key found\n";
		my $sha256 = sha256(pack('H*', $key));
		my $aes_key = substr($sha256, 0, 16);
		my $hmac_sha256_key = substr($sha256, 16, 16);

		if ($mac eq hmac_sha256($topic . $iv . $ciphertext, $hmac_sha256_key)) {
			# hmac sha256 ok
			$m = Crypt::Mode::CBC->new('AES');
			$uptime = $m->decrypt($ciphertext, $aes_key, $iv);

			# remove trailing nulls
			$uptime =~ s/[\x00\s]+$//;
			$uptime .= '';

			my $quoted_uptime = $dbh->quote($uptime);
			my $quoted_meter_serial = $dbh->quote($meter_serial);
			my $quoted_unix_time = $dbh->quote($unix_time);
			$dbh->do(qq[UPDATE meters SET \
							uptime = $quoted_uptime, \
							last_updated = $quoted_unix_time \
							WHERE serial = $quoted_meter_serial AND $quoted_unix_time > last_updated]) or warn "$!\n";
			warn $topic . "\t" . $uptime . "\n";			
		}
		else {
			# hmac sha256 not ok
			warn("serial $meter_serial checksum error\n");
		}
	}
}

sub v2_mqtt_ssid_handler {
	my ($topic, $message) = @_;
	my $m;
	
	unless ($topic =~ m!/ssid/v\d+/([^/]+)/(\d+)!) {
		return;
	}
	$meter_serial = $1;
	$unix_time = $2;
	
	$message =~ /(.{32})(.{16})(.+)/s;
	my $mac = $1;
	my $iv = $2;
	my $ciphertext = $3;
		
	my $sth = $dbh->prepare(qq[SELECT `key` FROM meters WHERE serial = ] . $dbh->quote($meter_serial) . qq[ LIMIT 1]);
	$sth->execute;
	if ($sth->rows) {
		my $key = $sth->fetchrow_hashref->{key} || warn "no aes key found\n";
		my $sha256 = sha256(pack('H*', $key));
		my $aes_key = substr($sha256, 0, 16);
		my $hmac_sha256_key = substr($sha256, 16, 16);

		if ($mac eq hmac_sha256($topic . $iv . $ciphertext, $hmac_sha256_key)) {
			# hmac sha256 ok
			$m = Crypt::Mode::CBC->new('AES');
			$ssid = $m->decrypt($ciphertext, $aes_key, $iv);

			# remove trailing nulls
			$ssid =~ s/[\x00\s]+$//;
			$ssid .= '';
        
			my $quoted_ssid = $dbh->quote($ssid);
			my $quoted_meter_serial = $dbh->quote($meter_serial);
			my $quoted_unix_time = $dbh->quote($unix_time);
			$dbh->do(qq[UPDATE meters SET \
							ssid = $quoted_ssid, \
							last_updated = $quoted_unix_time \
							WHERE serial = $quoted_meter_serial AND $quoted_unix_time > last_updated]) or warn "$!\n";
			warn $topic . "\t" . $ssid . "\n";			
		}
		else {
			# hmac sha256 not ok
			warn("serial $meter_serial checksum error\n");
		}
	}
}

sub v2_mqtt_rssi_handler {
	my ($topic, $message) = @_;
	my $m;
	
	unless ($topic =~ m!/rssi/v\d+/([^/]+)/(\d+)!) {
		return;
	}
	$meter_serial = $1;
	$unix_time = $2;
	
	$message =~ /(.{32})(.{16})(.+)/s;
	my $mac = $1;
	my $iv = $2;
	my $ciphertext = $3;
	
	my $sth = $dbh->prepare(qq[SELECT `key` FROM meters WHERE serial = ] . $dbh->quote($meter_serial) . qq[ LIMIT 1]);
	$sth->execute;
	if ($sth->rows) {
		my $key = $sth->fetchrow_hashref->{key} || warn "no aes key found\n";
		my $sha256 = sha256(pack('H*', $key));
		my $aes_key = substr($sha256, 0, 16);
		my $hmac_sha256_key = substr($sha256, 16, 16);

		if ($mac eq hmac_sha256($topic . $iv . $ciphertext, $hmac_sha256_key)) {
			# hmac sha256 ok
			$m = Crypt::Mode::CBC->new('AES');
			$rssi = $m->decrypt($ciphertext, $aes_key, $iv);

			# remove trailing nulls
			$rssi =~ s/[\x00\s]+$//;
			$rssi .= '';

			my $quoted_rssi = $dbh->quote($rssi);
			my $quoted_meter_serial = $dbh->quote($meter_serial);
			my $quoted_unix_time = $dbh->quote($unix_time);
			$dbh->do(qq[UPDATE meters SET \
							rssi = $quoted_rssi, \
							last_updated = $quoted_unix_time \
							WHERE serial = $quoted_meter_serial AND $quoted_unix_time > last_updated]) or warn "$!\n";
			warn $topic . "\t" . $rssi . "\n";			
		}
		else {
			# hmac sha256 not ok
			warn("serial $meter_serial checksum error\n");
		}
	}
}

sub v2_mqtt_wifi_status_handler {
	my ($topic, $message) = @_;
	my $m;
	
	unless ($topic =~ m!/wifi_status/v\d+/([^/]+)/(\d+)!) {
		return;
	}
	$meter_serial = $1;
	$unix_time = $2;
	
	$message =~ /(.{32})(.{16})(.+)/s;
	my $mac = $1;
	my $iv = $2;
	my $ciphertext = $3;
	
	my $sth = $dbh->prepare(qq[SELECT `key` FROM meters WHERE serial = ] . $dbh->quote($meter_serial) . qq[ LIMIT 1]);
	$sth->execute;
	if ($sth->rows) {
		my $key = $sth->fetchrow_hashref->{key} || warn "no aes key found\n";
		my $sha256 = sha256(pack('H*', $key));
		my $aes_key = substr($sha256, 0, 16);
		my $hmac_sha256_key = substr($sha256, 16, 16);

		if ($mac eq hmac_sha256($topic . $iv . $ciphertext, $hmac_sha256_key)) {
			# hmac sha256 ok
			$m = Crypt::Mode::CBC->new('AES');
			$wifi_status = $m->decrypt($ciphertext, $aes_key, $iv);

			# remove trailing nulls
			$wifi_status =~ s/[\x00\s]+$//;
			$wifi_status .= '';

			my $quoted_wifi_status = $dbh->quote($wifi_status);
			my $quoted_meter_serial = $dbh->quote($meter_serial);
			my $quoted_unix_time = $dbh->quote($unix_time);
			$dbh->do(qq[UPDATE meters SET \
							wifi_status = $quoted_wifi_status, \
							last_updated = $quoted_unix_time \
							WHERE serial = $quoted_meter_serial AND $quoted_unix_time > last_updated]) or warn "$!\n";
			warn $topic . "\t" . $wifi_status . "\n";			
		}
		else {
			# hmac sha256 not ok
			warn("serial $meter_serial checksum error\n");
		}
	}
}

sub v2_mqtt_ap_status_handler {
	my ($topic, $message) = @_;
	my $m;
	
	unless ($topic =~ m!/ap_status/v\d+/([^/]+)/(\d+)!) {
		return;
	}
	$meter_serial = $1;
	$unix_time = $2;
	
	$message =~ /(.{32})(.{16})(.+)/s;
	my $mac = $1;
	my $iv = $2;
	my $ciphertext = $3;
	
	my $sth = $dbh->prepare(qq[SELECT `key`, `sw_version` FROM meters WHERE serial = ] . $dbh->quote($meter_serial) . qq[ LIMIT 1]);
	$sth->execute;
	if ($sth->rows) {
		$_ = $sth->fetchrow_hashref;
		my $key = $_->{key} || warn "no aes key found\n";
		my $sha256 = sha256(pack('H*', $key));
		my $aes_key = substr($sha256, 0, 16);
		my $hmac_sha256_key = substr($sha256, 16, 16);

		if ($mac eq hmac_sha256($topic . $iv . $ciphertext, $hmac_sha256_key)) {
			# hmac sha256 ok
			$m = Crypt::Mode::CBC->new('AES');
			$ap_status = $m->decrypt($ciphertext, $aes_key, $iv);
			
			# remove trailing nulls
			$ap_status =~ s/[\x00\s]+$//;
			$ap_status .= '';

			# reverse ap_status for sw version higher than or equal to build #942
			my $orig_ap_status = $ap_status;
			$_->{sw_version} =~ /[^-]+-(\d+)/;
			if ($1 <= 942) {
				if ($orig_ap_status =~ /started/i) {
					$ap_status = 'stopped';
				}
				elsif ($orig_ap_status =~ /stopped/i) {
					$ap_status = 'started';
				}
				warn('reverse ap_status for sw version lower than or equal to build #942' . ", serial: $meter_serial, received ap_status: $orig_ap_status, saved ap_status: $ap_status\n");
			}

			my $quoted_ap_status = $dbh->quote($ap_status);
			my $quoted_meter_serial = $dbh->quote($meter_serial);
			my $quoted_unix_time = $dbh->quote($unix_time);
			$dbh->do(qq[UPDATE meters SET \
							ap_status = $quoted_ap_status, \
							last_updated = $quoted_unix_time \
							WHERE serial = $quoted_meter_serial AND $quoted_unix_time > last_updated]) or warn "$!\n";
			warn $topic . "\t" . $ap_status . "\n";			
		}
		else {
			# hmac sha256 not ok
			warn("serial $meter_serial checksum error\n");
		}
	}
}

sub v2_mqtt_reset_reason_handler {
	my ($topic, $message) = @_;
	my $m;
	
	unless ($topic =~ m!/reset_reason/v\d+/([^/]+)/(\d+)!) {
		return;
	}
	$meter_serial = $1;
	$unix_time = $2;
	
	$message =~ /(.{32})(.{16})(.+)/s;
	my $mac = $1;
	my $iv = $2;
	my $ciphertext = $3;
	
	my $sth = $dbh->prepare(qq[SELECT `key`, `sw_version` FROM meters WHERE serial = ] . $dbh->quote($meter_serial) . qq[ LIMIT 1]);
	$sth->execute;
	if ($sth->rows) {
		$_ = $sth->fetchrow_hashref;
		my $key = $_->{key} || warn "no aes key found\n";
		my $sha256 = sha256(pack('H*', $key));
		my $aes_key = substr($sha256, 0, 16);
		my $hmac_sha256_key = substr($sha256, 16, 16);

		if ($mac eq hmac_sha256($topic . $iv . $ciphertext, $hmac_sha256_key)) {
			# hmac sha256 ok
			$m = Crypt::Mode::CBC->new('AES');
			$reset_reason = $m->decrypt($ciphertext, $aes_key, $iv);
			
			# remove trailing nulls
			$reset_reason =~ s/[\x00\s]+$//;
			$reset_reason .= '';

			# handle long reset reason string
			$_->{sw_version} =~ /[^-]+-(\d+)/;
			if ($1 >= 1041) {
				$reset_reason =~ s/&/ /g;
			}
			
			my $quoted_reset_reason = $dbh->quote($reset_reason);
			my $quoted_meter_serial = $dbh->quote($meter_serial);
			my $quoted_unix_time = $dbh->quote($unix_time);
			$dbh->do(qq[UPDATE meters SET \
						        reset_reason = $quoted_reset_reason, \
							last_updated = $quoted_unix_time \
							WHERE serial = $quoted_meter_serial AND $quoted_unix_time > last_updated]) or warn "$!\n";
			warn $topic . "\t" . $reset_reason . "\n";			
		}
		else {
			# hmac sha256 not ok
			warn("serial $meter_serial checksum error\n");
		}
	}
}

sub v2_mqtt_scan_result_handler {
	my ($topic, $message) = @_;
	my $m;

	unless ($topic =~ m!/scan_result/v\d+/([^/]+)/(\d+)!) {
		return;
	}
	$protocol_version = $1;
	$meter_serial = $2;
	$unix_time = $3;
	
	$meter_serial = $1;
	$unix_time = $2;

	$message =~ /(.{32})(.{16})(.+)/s;
	my $mac = $1;
	my $iv = $2;
	my $ciphertext = $3;
		
	my $sth = $dbh->prepare(qq[SELECT `key` FROM meters WHERE serial = ] . $dbh->quote($meter_serial) . qq[ LIMIT 1]);
	$sth->execute;
	if ($sth->rows) {
		my $key = $sth->fetchrow_hashref->{key} || warn "no aes key found\n";
		my $sha256 = sha256(pack('H*', $key));
		my $aes_key = substr($sha256, 0, 16);
		my $hmac_sha256_key = substr($sha256, 16, 16);

		if ($mac eq hmac_sha256($topic . $iv . $ciphertext, $hmac_sha256_key)) {
			# hmac sha256 ok
			$m = Crypt::Mode::CBC->new('AES');
			$message = $m->decrypt($ciphertext, $aes_key, $iv);
			
			# remove trailing nulls
			$message =~ s/[\x00\s]+$//;
			$message .= '';

			# parse message
			$message =~ s/&$//;
	
			my ($key, $value, $unit);
			my @key_value_list = split(/&/, $message);
			my $key_value; 
			foreach $key_value (@key_value_list) {
				if (($key, $value) = $key_value =~ /([^=]*)=(.*)/) {
					$mqtt_data->{$key} = $value;
				}
			}		
			# save to db
			my $sth = $dbh->prepare(qq[INSERT INTO `wifi_scan` (
				`serial`,
				`ssid`,
				`bssid`,
				`rssi`,
				`channel`,
				`unix_time`
				) VALUES (] . 
				$dbh->quote($meter_serial) . ',' . 
				$dbh->quote($mqtt_data->{ssid}) . ',' . 
				$dbh->quote($mqtt_data->{bssid}) . ',' . 
				$dbh->quote($mqtt_data->{rssi}) . ',' . 
				$dbh->quote($mqtt_data->{channel}) . ',' . 
				'UNIX_TIMESTAMP()' . qq[)]);
			$sth->execute || warn("can't log to db\n");
			$sth->finish;
		
			warn $topic . "\t" . $message . "\n";
		}
		else {
			# hmac sha256 not ok

		}
	}
	$mqtt_data = undef;
}

sub v2_mqtt_sample_handler {
	my ($topic, $message) = @_;
	my $m;

	unless ($topic =~ m!/sample/v\d+/([^/]+)/(\d+)!) {
		return;
	}
	$protocol_version = $1;
	$meter_serial = $2;
	$unix_time = $3;
	
	$meter_serial = $1;
	$unix_time = $2;

	$message =~ /(.{32})(.{16})(.+)/s;
	my $mac = $1;
	my $iv = $2;
	my $ciphertext = $3;
		
	my $sth = $dbh->prepare(qq[SELECT `key` FROM meters WHERE serial = ] . $dbh->quote($meter_serial) . qq[ LIMIT 1]);
	$sth->execute;
	if ($sth->rows) {
		my $key = $sth->fetchrow_hashref->{key} || warn "no aes key found\n";
		my $sha256 = sha256(pack('H*', $key));
		my $aes_key = substr($sha256, 0, 16);
		my $hmac_sha256_key = substr($sha256, 16, 16);

		if ($mac eq hmac_sha256($topic . $iv . $ciphertext, $hmac_sha256_key)) {
			# hmac sha256 ok
			$m = Crypt::Mode::CBC->new('AES');
			$message = $m->decrypt($ciphertext, $aes_key, $iv);
			
			# remove trailing nulls
			$message =~ s/[\x00\s]+$//;
			$message .= '';

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
			$sth->execute || warn("can't log to db\n");
			$sth->finish;
		
			# update last_updated time stamp
			my $quoted_meter_serial = $dbh->quote($meter_serial);
			my $quoted_unix_time = $dbh->quote($unix_time);
			$dbh->do(qq[UPDATE meters SET \
							last_updated = $quoted_unix_time \
							WHERE serial = $quoted_meter_serial AND $quoted_unix_time > last_updated]) or warn "$!\n";
			warn $topic . "\t" . $message . "\n";
		}
		else {
			# hmac sha256 not ok

		}
	}
	$mqtt_data = undef;
}


sub v2_mqtt_crypto_test_handler {
	my ($topic, $message) = @_;
	my $m;

	unless ($topic =~ m!/crypto/v\d+/([^/]+)/(\d+)!) {
	        return;
	}
	$meter_serial = $1;
	$unix_time = $2;

	$message =~ /(.{32})(.{16})(.+)/s;
	my $mac = $1;
	my $iv = $2;
	my $ciphertext = $3;
		
	my $sth = $dbh->prepare(qq[SELECT `key` FROM meters WHERE serial = ] . $dbh->quote($meter_serial) . qq[ LIMIT 1]);
	$sth->execute;
	if ($sth->rows) {
		my $key = $sth->fetchrow_hashref->{key} || warn "no aes key found\n";
		my $sha256 = sha256(pack('H*', $key));
		my $aes_key = substr($sha256, 0, 16);
		my $hmac_sha256_key = substr($sha256, 16, 16);

		if ($mac eq hmac_sha256($topic . $iv . $ciphertext, $hmac_sha256_key)) {
			# hmac sha256 ok
			$m = Crypt::Mode::CBC->new('AES');
			$message = $m->decrypt($ciphertext, $aes_key, $iv);

			# remove trailing nulls
			$message =~ s/[\x00\s]+$//;
			$message .= '';

			warn Dumper({	"message" => unpack('H*', $message),
							"aes key" => unpack('H*', $aes_key),
							"hmac sha256 key" => unpack('H*', $hmac_sha256_key),
							"iv" => unpack('H*', $iv),
							"ciphertext" => unpack('H*', $ciphertext),
							"mac" => unpack('H*', $mac),
							"message" => $message,
							"cleartext" => unpack('H*', $message)
						});
		}
		else {
			# hmac sha256 not ok
			warn("serial $meter_serial checksum error\n");
		}
	}
}

__END__
