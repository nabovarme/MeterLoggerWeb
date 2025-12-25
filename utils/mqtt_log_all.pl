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
use Getopt::Long;
use Curses;

use Nabovarme::Db;

STDOUT->autoflush(1);

openlog($0, "ndelay,pid", "local0");
syslog('info', "starting...");

# Command-line options
my $topic_only		= 0;
my $help			= 0;
my $client_count	= 0;
my $graphics_mode	= 0;

GetOptions(
	'topic-only|t'	=> \$topic_only,
	'help|h'		=> \$help,
	'client-count|c'=> \$client_count,
	'graphics|g'	=> \$graphics_mode,
) or usage();

usage() if $help;

print "Press Ctrl+C to exit.\n";

# Connect to DB
my $dbh;
if ($dbh = Nabovarme::Db->my_connect) {
	$dbh->{'mysql_auto_reconnect'} = 1;
	syslog('info', "connected to db");
} else {
	syslog('info', "cant't connect to db $!");
	die $!;
}

# Graphics mode variables
my ($top_win, $log_win, @log_lines, $client_count_current, $max_lines);

# Initialize graphics mode if requested
if ($graphics_mode) {
	initscr();
	noecho();
	curs_set(0);
	cbreak();

	my $main = stdscr();
	my ($rows, $cols);
	getmaxyx($main, $rows, $cols);

	# Top window: client count
	$top_win = newwin(3, $cols, 0, 0);

	# Log window: visible MQTT messages
	$max_lines = $rows - 3;
	$log_win = newwin($max_lines, $cols, 3, 0);
	@log_lines = ();

	# Initial draw
	display_top_window();
	$log_win->refresh();

	# Signal handlers
	$SIG{INT} = sub { endwin(); $dbh->disconnect() if $dbh; print "Exiting graphics mode.\n"; exit; };
	$SIG{HUP} = sub { endwin(); $dbh->disconnect() if $dbh; print "Exiting graphics mode due to HUP.\n"; exit; };
}

# Mode selection
if ($client_count && !$graphics_mode) {
	print_client_count();
	exit;
}

# Start normal MQTT loop
run_mqtt_loop();

# =============================================================================
# Subroutines
# =============================================================================

sub usage {
	print "Usage: $0 [options] [serial]\n";
	print "\n";
	print "Options:\n";
	print "\t-t, --topic-only   Print only the MQTT topic, skip decoded data\n";
	print "\t-c, --client-count Continuously print number of connected MQTT clients\n";
	print "\t-g, --graphics     Show clients on top and MQTT messages below (Curses mode)\n";
	print "\t-h, --help         Show this help message\n";
	print "\n";
	print "If no serial is specified, all serials are processed.\n";
	exit;
}

sub print_client_count {
	my $sys_mqtt = Net::MQTT::Simple->new('mqtt');
	my $count;

	$SIG{INT} = sub { print "\nExiting client count mode.\n"; exit; };
	$SIG{HUP} = sub { print "\nExiting client count mode due to HUP.\n"; exit; };

	$sys_mqtt->run(
		'$SYS/broker/clients/connected' => sub {
			$count = $_[1];
			print "MQTT clients connected: $count\n";
		}
	);
}

sub run_mqtt_loop {
	my $mqtt = Net::MQTT::Simple->new('mqtt');
	my $mqtt_data = undef;

	$SIG{INT} = sub {
		endwin() if $graphics_mode;
		$dbh->disconnect() if $dbh;
		print "disconnected\n";
		exit;
	};
	$SIG{HUP} = sub {
		endwin() if $graphics_mode;
		$dbh->disconnect() if $dbh;
		print "disconnected due to HUP\n";
		exit;
	};

	$mqtt->run(
		'/#' => \&v2_mqtt_handler,
		'$SYS/broker/clients/connected' => sub {
			$client_count_current = $_[1];
			display_top_window() if $graphics_mode;
		}
	);
}

sub v2_mqtt_handler {
	my ($topic, $message) = @_;

	unless ($topic =~ m!/[^/]+/v(\d+)/([^/]+)/(\d+)!) { return; }
	my $protocol_version	= $1;
	my $meter_serial	= $2;
	my $unix_time		= $3;

	if ($ARGV[0] && $meter_serial ne $ARGV[0]) { return; }

	if ($topic_only) {
		$message = '';
	} else {
		$message =~ /(.{32})(.{16})(.+)/s;
		my ($mac,$iv,$ciphertext) = ($1,$2,$3);

		my $sth = $dbh->prepare("SELECT `key` FROM meters WHERE serial = ".$dbh->quote($meter_serial)." LIMIT 1");
		$sth->execute;
		if ($sth->rows) {
			my $key = $sth->fetchrow_hashref->{key} || warn "no aes key found";
			my $sha256 = sha256(pack('H*', $key));
			my $aes_key = substr($sha256,0,16);
			my $hmac_sha256_key = substr($sha256,16,16);
			if ($mac eq hmac_sha256($topic.$iv.$ciphertext,$hmac_sha256_key)) {
				my $cbc = Crypt::Mode::CBC->new('AES');
				$message = $cbc->decrypt($ciphertext,$aes_key,$iv);
			} else {
				$message = "[HMAC verification failed]";
			}
		}
	}

	if ($graphics_mode) {
		add_log_message("$topic\t$message");
	} else {
		print "$topic\t$message\n";
	}
}

# -------------------------------------------------------------------------
# Add new message to the log window (smooth scrolling, no flicker)
# -------------------------------------------------------------------------
sub add_log_message {
	my ($msg) = @_;

	# Append message to circular buffer
	push @log_lines, $msg;

	# Keep only last $max_lines
	@log_lines = @log_lines[-$max_lines..-1] if @log_lines > $max_lines;

	# Draw all visible lines
	for my $i (0 .. $#log_lines) {
		$log_win->move($i,0);
		$log_win->clrtoeol();
		$log_win->addstr($log_lines[$i]);
	}

	$log_win->refresh();
}

# -------------------------------------------------------------------------
# Redraw top window with client count
# -------------------------------------------------------------------------
sub display_top_window {
	$top_win->clear();
	$top_win->attron(A_BOLD);  # enable bold
	$top_win->addstr(0,0,"MQTT clients connected: $client_count_current");
	$top_win->attroff(A_BOLD); # disable bold
	$top_win->move(1,0);
	my ($rows, $cols);
	getmaxyx($top_win, $rows, $cols);
	$top_win->hline('-', $cols);
	$top_win->refresh();
}

__END__
