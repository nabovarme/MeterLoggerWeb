#!/usr/bin/perl -w

# =============================================================================
# MQTT Meter Message Encryption and Integrity Overview
#
# Each meter message is encrypted and authenticated as follows:
#
# 1. AES-CBC Encryption:
#    - Payload is encrypted using AES in CBC mode.
#    - AES key is derived from the meter's stored key:
#        * SHA-256 hash of the hex-encoded meter key is computed.
#        * First 16 bytes of the hash are used as the AES encryption key.
#    - Each message includes a 16-byte random Initialization Vector (IV)
#      to ensure identical plaintexts produce different ciphertexts.
#
# 2. HMAC-SHA256 Message Authentication:
#    - To ensure integrity and authenticity, an HMAC-SHA256 is computed
#      over the concatenation: topic || IV || ciphertext.
#    - HMAC key is derived from the last 16 bytes of SHA-256(meter key).
#    - The first 32 bytes of the message contain the HMAC.
#    - The script verifies the HMAC before decryption.
#
# 3. Message Structure:
#       [32-byte HMAC][16-byte IV][Ciphertext]
#
# 4. Decryption Process:
#    - Extract HMAC, IV, and ciphertext from the message.
#    - Verify HMAC against topic, IV, and ciphertext.
#    - Only decrypt if HMAC verification succeeds.
#    - Decrypt using AES-CBC with derived key and IV from message.
# =============================================================================

use strict;
use warnings;
use Data::Dumper;
use Sys::Syslog;
use Net::MQTT::Simple;
use DBI;
use Crypt::Mode::CBC;
use Digest::SHA qw( sha256 hmac_sha256 );
use Config;
use Getopt::Long;

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

# Command-line options
my $topic_only   = 0;
my $help         = 0;
my $client_count = 0;

GetOptions(
	'topic-only|t'   => \$topic_only,
	'help|h'         => \$help,
	'client-count|c' => \$client_count,
) or usage();

usage() if $help;

# Inform user how to exit
print "Press Ctrl+C to exit.\n";

sub usage {
	print "Usage: $0 [options] [serial]\n";
	print "\n";
	print "Options:\n";
	print "\t-t, --topic-only   Print only the MQTT topic, skip decoded data\n";
	print "\t-c, --client-count Continuously print number of connected MQTT clients\n";
	print "\t-h, --help         Show this help message\n";
	print "\n";
	print "If no serial is specified, all serials are processed.\n";
	exit;
}

# If client-count is requested, run continuous client count mode
if ($client_count) {
	print_client_count();
	exit;
}

sub print_client_count {
	my $sys_mqtt = Net::MQTT::Simple->new('mqtt');
	my $count;

	# Capture Ctrl+C to exit gracefully
	$SIG{INT} = sub {
		print "\nExiting client count mode.\n";
		exit;
	};

	# Subscribe to the retained topic and print whenever it changes
	$sys_mqtt->run(
		'$SYS/broker/clients/connected' => sub {
			my ($topic, $msg) = @_;
			$count = $msg;
			print "Connected MQTT clients: $count\n";
		}
	);
}

my $mqtt = Net::MQTT::Simple->new(q[mqtt]);
my $mqtt_data = undef;

# connect to db
my $dbh;
if ($dbh = Nabovarme::Db->my_connect) {
	$dbh->{'mysql_auto_reconnect'} = 1;
	syslog('info', "connected to db");
} else {
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
	$meter_serial     = $2;
	$unix_time        = $3;

	# filter by serial if argument is given
	if ($ARGV[0]) {
		if ($meter_serial ne $ARGV[0]) {
			return;
		}
	}

	# if topic-only mode, skip decryption/HMAC and just print
	if ($topic_only) {
		print $topic . "\n";
		return;
	}

	$message =~ /(.{32})(.{16})(.+)/s;
	my $mac        = $1;
	my $iv         = $2;
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
			print $topic . "\t" . $message . "\n";
		} else {
			# hmac sha256 not ok
		}
	}
	$mqtt_data = undef;
}

__END__
