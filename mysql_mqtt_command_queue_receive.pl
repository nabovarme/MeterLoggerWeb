#!/usr/bin/perl -w

use strict;
use Data::Dumper;
use Net::MQTT::Simple;
use DBI;
use Crypt::Mode::CBC;
use Digest::SHA qw( sha256 hmac_sha256 );
use Config;

use lib qw( /etc/apache2/perl );
use lib qw( /opt/local/apache2/perl );
use lib qw( /Users/loppen/Documents/stoffer/MeterLoggerWeb/perl );
use lib qw( /Users/stoffer/src/esp8266/MeterLoggerWeb/perl );
use Nabovarme::Db;

use constant CONFIG_FILE => qw (/etc/Nabovarme.conf );

my $config = new Config::Simple(CONFIG_FILE) || die $!;
my $mqtt_host = $config->param('mqtt_host');
my $mqtt_port = $config->param('mqtt_port');

$SIG{INT} = \&sig_int_handler;

my $dbh;
my $sth;
my $d;

warn("starting...\n");


sub sig_int_handler {

	die $!;
}

sub mqtt_handler {
	my ($topic, $message) = @_;
	
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
	
	$message =~ /(.{32})(.{16})(.+)/s;

	my $mac = $1;
	my $iv = $2;
	my $ciphertext = $3;

	my ($function) = $topic =~ m!/([^/]+)!;
	if ($function =~ /^config$/i) {
		return;
	}

	$sth = $dbh->prepare(qq[SELECT `key`, `sw_version` FROM meters WHERE serial = ] . $dbh->quote($meter_serial) . qq[ LIMIT 1]);
	$sth->execute;
	if ($sth->rows) {
		$d = $sth->fetchrow_hashref;
		my $key = $d->{key} || warn "no aes key found\n";
		
#		warn "received mqtt function " . $function . " to " . $meter_serial . "\n";
#		syslog('info', "received mqtt function " . $function . " to " . $meter_serial);

		# only for sw version higher than or equal to build #923
		$d->{sw_version} =~ /[^-]+-(\d+)/;
		$sw_version = $1;
		if ($sw_version < 923) {
			return;
		}
		
		# handle special case
		if ($function =~ /^scan_result$/i) {
			warn "received mqtt reply from $meter_serial: $function, deleting from mysql queue\n";
			# do mysql stuff here
			$dbh->do(qq[DELETE FROM command_queue WHERE `serial` = ] . $dbh->quote($meter_serial) . qq[ AND `function` LIKE 'scan']) or warn $!;
			return;
		}
#		elsif ($function =~ /^open$/i && ($sw_version < 1033)) {
#			warn "received mqtt reply from $meter_serial: $function, deleting from mysql queue\n";
#			syslog('info', "received mqtt reply from $meter_serial: $function, deleting from mysql queue");
#			# do mysql stuff here
#			$dbh->do(qq[DELETE FROM command_queue WHERE `serial` = ] . $dbh->quote($meter_serial) . qq[ AND `function` LIKE 'open_until%']) or warn $!;
#			return;
#		}
		
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
					AND `param` > ] . $dbh->quote($cleartext - 1) . qq[ \
					AND `param` < ] . $dbh->quote($cleartext + 1) . qq[ \
					LIMIT 1]);
				$sth->execute;
				if ($sth->rows) {
					warn "received mqtt reply from $meter_serial: $function, param: $cleartext, deleting from mysql queue\n";
					$dbh->do(qq[DELETE FROM command_queue WHERE `serial` = ] . $dbh->quote($meter_serial) . qq[ AND `function` LIKE ] . $dbh->quote($function)) or warn $!;
				}
				else {
					warn "received mqtt reply from $meter_serial: $function, param: $cleartext not matching queue value\n";
				}
				return;
			}

			# handle general case
			$sth = $dbh->prepare(qq[SELECT `serial` FROM command_queue WHERE serial = ] . $dbh->quote($meter_serial) . qq[ AND `function` LIKE ] . $dbh->quote($function) . qq[ LIMIT 1]);

			# mark it for deletion
			$sth = $dbh->prepare(qq[SELECT `id`, `has_callback` FROM command_queue \
				WHERE `serial` = ] . $dbh->quote($meter_serial) . qq[ AND `function` LIKE ] . $dbh->quote($function) . qq[ AND `state` = 'sent']);
			$sth->execute;
			if ($d = $sth->fetchrow_hashref) {
				if ($d->{has_callback}) {
					warn "mark serial $meter_serial, command $function for deletion\n";
					$dbh->do(qq[UPDATE command_queue SET \
						`state` = 'received', \
					    `param` = ] . $dbh->quote($cleartext) . qq[ \
						WHERE `id` = ] . $d->{id}) or warn $!;
				}
				else {
					# delete if has_callback not set
					warn "deleting serial $meter_serial, command $function from mysql queue\n";
#					$dbh->do(qq[DELETE FROM command_queue WHERE `id` = ] . $d->{id});
					$dbh->do(qq[DELETE FROM command_queue WHERE `serial` = ] . $dbh->quote($meter_serial) . qq[ AND `function` LIKE ] . $dbh->quote($function) . qq[ AND `state` = 'sent']);
				}
			}
		}
		else {
			# hmac sha256 not ok
			warn "serial $meter_serial checksum error\n";  
		}
	}
}

# connect to db
if ($dbh = Nabovarme::Db->my_connect) {
	$dbh->{'mysql_auto_reconnect'} = 1;
}
else {
	warn("cant't connect to db $!\n");
	die $!;
}

my $subscribe_mqtt = Net::MQTT::Simple->new($mqtt_host . ':' . $mqtt_port);
$subscribe_mqtt->run(q[/#], \&mqtt_handler);

1;

__END__
