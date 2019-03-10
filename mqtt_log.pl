#!/usr/bin/perl -w

use strict;
use Data::Dumper;
use Sys::Syslog;
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

openlog($0, "ndelay,pid", "local0");
syslog('info', "starting...");

my $unix_time;
my $meter_serial;
my $flash_error;
my $reset_reason;

my $mqtt = Net::MQTT::Simple->new($config->param('mqtt_host'));

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
$mqtt->run(	q[/offline/v1/#] => \&mqtt_offline_handler,
	q[/flash_error/v2/#] => \&mqtt_flash_error_handler,
	q[/reset_reason/v2/#] => \&mqtt_reset_reason_handler,
);

# end of main


sub mqtt_offline_handler {
	my ($topic, $message) = @_;

	unless ($topic =~ m!/offline/v\d+/([^/]+)!) {
	        return;
	}
	$meter_serial = $1;
	$unix_time = time();

	my $quoted_meter_serial = $dbh->quote($meter_serial);
	my $quoted_unix_time = $dbh->quote($unix_time);
	$dbh->do(qq[INSERT INTO `log` (`serial`, `function`, `unix_time`) VALUES ($quoted_meter_serial, 'offline', $quoted_unix_time)]) or warn $!;
        syslog('info', $topic . "\t" . 'offline');
	warn $topic . "\t" . 'offline' . "\n";
}

sub mqtt_flash_error_handler {
	my ($topic, $message) = @_;
	my $m;
	
	unless ($topic =~ m!/flash_error/v\d+/([^/]+)/(\d+)!) {
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
		my $key = $sth->fetchrow_hashref->{key} || warn "no aes key found";
		my $sha256 = sha256(pack('H*', $key));
		my $aes_key = substr($sha256, 0, 16);
		my $hmac_sha256_key = substr($sha256, 16, 16);

		if ($mac eq hmac_sha256($topic . $iv . $ciphertext, $hmac_sha256_key)) {
			# hmac sha256 ok
			$m = Crypt::Mode::CBC->new('AES');
			$flash_error = $m->decrypt($ciphertext, $aes_key, $iv);
			
			# remove trailing nulls
			$flash_error =~ s/[\x00\s]+$//;
			$flash_error .= '';

			my $quoted_flash_error = $dbh->quote($flash_error);
			my $quoted_meter_serial = $dbh->quote($meter_serial);
			my $quoted_unix_time = $dbh->quote($unix_time);
                	$dbh->do(qq[INSERT INTO `log` (`serial`, `function`, `param`, `unix_time`) VALUES ($quoted_meter_serial, 'flash_error', $quoted_flash_error, $quoted_unix_time)]) or warn $!;
			syslog('info', $topic . "\t" . 'flash_error');
			warn $topic . "\t" . 'flash_error' . "\n";
			
		}
		else {
			# hmac sha256 not ok
			warn Dumper("serial $meter_serial checksum error");
		}
	}
}

sub mqtt_reset_reason_handler {
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
			$reset_reason = $m->decrypt($ciphertext, $aes_key, $iv);
			
			# remove trailing nulls
			$reset_reason =~ s/[\x00\s]+$//;
			$reset_reason .= '';

			my $quoted_reset_reason = $dbh->quote($reset_reason);
			my $quoted_meter_serial = $dbh->quote($meter_serial);
			my $quoted_unix_time = $dbh->quote($unix_time);
                	$dbh->do(qq[INSERT INTO `log` (`serial`, `function`, `param`, `unix_time`) VALUES ($quoted_meter_serial, 'reset_reason', $quoted_reset_reason, $quoted_unix_time)]) or warn $!;
			syslog('info', $topic . "\t" . 'reset_reason');
			warn $topic . "\t" . 'reset_reason' . "\n";
			
		}
		else {
			# hmac sha256 not ok
			warn Dumper("serial $meter_serial checksum error");
		}
	}
}

__END__
