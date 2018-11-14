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
use Time::HiRes qw( usleep );
use threads;

use lib qw( /etc/apache2/perl );
use lib qw( /opt/local/apache2/perl/ );
use Nabovarme::Db;

use constant DELAY_AFTER_SENDING => 1_000_000;				# 1 second
use constant DELAY_AFTER_SENDING_RECONNECT => 12_000_000;	# 12 seconds

$SIG{INT} = \&sig_int_handler;

openlog($0, "ndelay,pid", "local0");
syslog('info', "starting...");

my $unix_time;
my $meter_serial;
my $mqtt_data = undef;
#my $mqtt_count = 0;

my $dbh;
my $sth;
my $d;

my $key;
my $m;
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

sub start_thread {
	my $key = $_[0]->{'key'};
	my $sha256 = sha256(pack('H*', $key));
	my $aes_key = substr($sha256, 0, 16);
	my $hmac_sha256_key = substr($sha256, 16, 16);
	
	my $dbh_recheck;
	my $sth_recheck;
	my $d_recheck;
	# connect to db
	if ($dbh_recheck = Nabovarme::Db->my_connect) {
		$dbh_recheck->{'mysql_auto_reconnect'} = 1;
		syslog('info', "connected to db in thread");
	}
	else {
		syslog('info', "cant't connect to db $!");
		die $!;
	}
	
	$m = Crypt::Mode::CBC->new('AES');

	$_[0]->{sw_version} =~ /[^-]+-(\d+)/;
	if ($1 >= 1032) {
		# use combined set_ssid and set_pwd for newer firmware
		if (defined($_[0]->{wifi_set_ssid}) && defined($_[0]->{wifi_set_pwd})) {
			# send set_ssid_pwd
			warn "\tsend mqtt command to change ssid to " . $_[0]->{wifi_set_ssid} . " to " . $_[0]->{serial};
			syslog('info', "    send mqtt command to change ssid to " . $_[0]->{wifi_set_ssid} . " to " . $_[0]->{serial});
			# escape & and =
			$_[0]->{serial} =~ s/&/%26/g;
			$_[0]->{serial} =~ s/=/%61/g;
			$_[0]->{wifi_set_pwd} =~ s/&/%26/g;
			$_[0]->{wifi_set_pwd} =~ s/=/%61/g;
			$topic = '/config/v2/' . $_[0]->{serial} . '/' . time() . '/set_ssid_pwd';
			$message = "ssid=" . $_[0]->{wifi_set_ssid} . "&pwd=" . $_[0]->{wifi_set_pwd} . "\0";
			$iv = join('', map(chr(int rand(256)), 1..16));
			$message = $m->encrypt($message, $aes_key, $iv);
			$message = $iv . $message;
			$hmac_sha256_hash = hmac_sha256($topic . $message, $hmac_sha256_key);
			$mqtt->publish($topic => $hmac_sha256_hash . $message);
			warn "\twaiting " . DELAY_AFTER_SENDING / 1_000_000 . " seconds for reply";
			syslog('info', "    waiting " . DELAY_AFTER_SENDING / 1_000_000 . " seconds for reply");
			usleep(DELAY_AFTER_SENDING);	
		}
	}
	else {
		if (defined($_[0]->{wifi_set_ssid})) {
			# send set_ssid
			warn "\tsend mqtt command to change ssid to " . $_[0]->{wifi_set_ssid} . " to " . $_[0]->{serial};
			syslog('info', "    send mqtt command to change ssid to " . $_[0]->{wifi_set_ssid} . " to " . $_[0]->{serial});
			$topic = '/config/v2/' . $_[0]->{serial} . '/' . time() . '/set_ssid';
			$message = $_[0]->{wifi_set_ssid} . "\0";
			$iv = join('', map(chr(int rand(256)), 1..16));
			$message = $m->encrypt($message, $aes_key, $iv);
			$message = $iv . $message;
			$hmac_sha256_hash = hmac_sha256($topic . $message, $hmac_sha256_key);
			$mqtt->publish($topic => $hmac_sha256_hash . $message);
			warn "\twaiting " . DELAY_AFTER_SENDING / 1_000_000 . " seconds for reply";
			syslog('info', "    waiting " . DELAY_AFTER_SENDING / 1_000_000 . " seconds for reply");
			usleep(DELAY_AFTER_SENDING);	
		}
		if (defined($_[0]->{wifi_set_pwd})) {
			# send set_pwd
			warn "\tsend mqtt command to change wifi pwd to " . $_[0]->{serial};
			syslog('info', "    send mqtt command to change wifi pwd to " . $_[0]->{serial});
			$topic = '/config/v2/' . $_[0]->{serial} . '/' . time() . '/set_pwd';
			$message = $_[0]->{wifi_set_pwd} . "\0";
			$iv = join('', map(chr(int rand(256)), 1..16));
			$message = $m->encrypt($message, $aes_key, $iv);
			$message = $iv . $message;
			$hmac_sha256_hash = hmac_sha256($topic . $message, $hmac_sha256_key);
			$mqtt->publish($topic => $hmac_sha256_hash . $message);
			warn "\twaiting " . DELAY_AFTER_SENDING / 1_000_000 . " seconds for reply";
			syslog('info', "    waiting " . DELAY_AFTER_SENDING / 1_000_000 . " seconds for reply");
			usleep(DELAY_AFTER_SENDING);
		}
	}
	
	# send reconnect
	warn "\tsend mqtt command to reconnect to " . $_[0]->{serial};
	syslog('info', "    send mqtt command to reconnect to " . $_[0]->{serial});
	$topic = '/config/v2/' . $_[0]->{serial} . '/' . time() . '/reconnect';
	$message = '';
	$iv = join('', map(chr(int rand(256)), 1..16));
	$message = $m->encrypt($message, $aes_key, $iv);
	$message = $iv . $message;
	$hmac_sha256_hash = hmac_sha256($topic . $message, $hmac_sha256_key);
	$mqtt->publish($topic => $hmac_sha256_hash . $message);
	warn "\twaiting " . DELAY_AFTER_SENDING_RECONNECT / 1_000_000 . " seconds for reconnect";
	syslog('info', "    waiting " . DELAY_AFTER_SENDING_RECONNECT / 1_000_000 . " seconds for reconnect");
	usleep(DELAY_AFTER_SENDING_RECONNECT);
	
	# send wifi_status
	warn "\tsend mqtt command to get wifi status to " . $_[0]->{serial};
	syslog('info', "    send mqtt command to get wifi status to " . $_[0]->{serial});
	$topic = '/config/v2/' . $_[0]->{serial} . '/' . time() . '/wifi_status';
	$message = '';
	$iv = join('', map(chr(int rand(256)), 1..16));
	$message = $m->encrypt($message, $aes_key, $iv);
	$message = $iv . $message;
	$hmac_sha256_hash = hmac_sha256($topic . $message, $hmac_sha256_key);
	$mqtt->publish($topic => $hmac_sha256_hash . $message);
	warn "\twaiting " . DELAY_AFTER_SENDING / 1_000_000 . " seconds for reply";
	syslog('info', "    waiting " . DELAY_AFTER_SENDING / 1_000_000 . " seconds for reply");
	usleep(DELAY_AFTER_SENDING);
	
	# send ssid
	warn "\tsend mqtt command to get ssid to" . $_[0]->{serial};
	syslog('info', "    send mqtt command to get ssid to " . $_[0]->{serial});
	$topic = '/config/v2/' . $_[0]->{serial} . '/' . time() . '/ssid';
	$message = '';
	$iv = join('', map(chr(int rand(256)), 1..16));
	$message = $m->encrypt($message, $aes_key, $iv);
	$message = $iv . $message;
	$hmac_sha256_hash = hmac_sha256($topic . $message, $hmac_sha256_key);
	$mqtt->publish($topic => $hmac_sha256_hash . $message);
	warn "\twaiting " . DELAY_AFTER_SENDING / 1_000_000 . " seconds for reply";
	syslog('info', "    waiting " . DELAY_AFTER_SENDING / 1_000_000 . " seconds for reply");
	usleep(DELAY_AFTER_SENDING);
	
	# re-check wifi_status
	my $wifi_status;
	my $quoted_serial = $dbh_recheck->quote($_[0]->{serial});
	$sth_recheck = $dbh_recheck->prepare(qq[SELECT `wifi_status` FROM meters WHERE `serial` = $quoted_serial]);
	$sth_recheck->execute;
	
	if ($d_recheck = $sth_recheck->fetchrow_hashref) {
		$wifi_status = $d_recheck->{wifi_status};
	}
	if ($wifi_status =~ /^connected/i) {
		# we asume that supplied ssid/pwd make MeterLogger able to connect, so we can delete it from the db
		warn "done changing network to " . $_[0]->{wifi_set_ssid} . " for " . $_[0]->{serial};
		syslog('info', "done changing network to " . $_[0]->{wifi_set_ssid} . " for " . $_[0]->{serial});
		my $quoted_meter_serial = $dbh_recheck->quote($_[0]->{serial});
		$dbh_recheck->do(qq[UPDATE meters SET \
						wifi_set_ssid = NULL, \
						wifi_set_pwd = NULL \
						WHERE serial = $quoted_meter_serial]) or warn $!;
	
	}
}

while (1) {
	my @threads = ();
	$sth = $dbh->prepare(qq[SELECT `serial`, `wifi_status`, `wifi_set_ssid`, `wifi_set_pwd`, `key`, `sw_version` FROM meters WHERE `wifi_status` = 'reconnect']);
	$sth->execute;
	
	while ($d = $sth->fetchrow_hashref) {
		my $thr = threads->create(\&start_thread, $d);
		push(@threads, $thr);
	}
	foreach (@threads) {
		my $t = $_->join;
	}
	sleep 20;
}

sub sig_int_handler {

	die $!;
}

1;

__END__
