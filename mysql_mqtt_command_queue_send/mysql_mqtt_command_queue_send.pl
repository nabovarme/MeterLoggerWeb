#!/usr/bin/perl -w

use strict;
use warnings;
use Data::Dumper;
use Net::MQTT::Simple;
use DBI;
use Crypt::Mode::CBC;
use Digest::SHA qw(sha256 hmac_sha256);
use Time::HiRes qw(usleep);

use Nabovarme::Db;
use Nabovarme::Utils;

# --- Constants ---
use constant DELAY_BETWEEN_RETRANSMIT   => 10;       # 10 seconds
use constant DELAY_BETWEEN_SERIALS      => 1;        # 1 second delay when switching functions
use constant DB_POLL_DELAY_USEC         => 200_000;  # 200 ms for fast UI responsiveness
use constant DELAY_BETWEEN_COMMAND_USEC => 20_000;   # 20 mS

# --- Config from environment ---

my $mqtt_host = $ENV{'MQTT_HOST'}
	or log_die("ERROR: MQTT_HOST environment variable not set", {-no_script_name => 1});

my $mqtt_port = $ENV{'MQTT_PORT'}
	or log_die("ERROR: MQTT_PORT environment variable not set", {-no_script_name => 1});

# --- Globals ---
my ($dbh, $sth, $d);
my ($current_function, $last_function);

#print Dumper $pp->pidfile();

log_info("starting...", {-no_script_name => 1});

# --- MQTT publisher ---
my $publish_mqtt = Net::MQTT::Simple->new($mqtt_host . ':' . $mqtt_port);

# --- SIGINT handler ---
$SIG{INT} = sub {
	$publish_mqtt->disconnect();
	log_die("Interrupted", {-no_script_name => 1});
};

# connect to db
if ($dbh = Nabovarme::Db->my_connect) {
	$dbh->{'mysql_auto_reconnect'} = 1;
	$dbh->{'mysql_enable_utf8'} = 0;	# get data as from queue as byte string
}
else {
	log_die("cant't connect to db $!", {-no_script_name => 1});
}

my $m = Crypt::Mode::CBC->new('AES');

while (1) {
	# Clean up old states
	$dbh->do(qq[DELETE FROM command_queue WHERE `state` = 'timeout'])
		or warn $DBI::errstr;
	# Garbage collect orphaned completed commands (where the HTTP client timed out and stopped waiting)
	$dbh->do(qq[DELETE FROM command_queue WHERE `state` = 'received' AND `unix_time` < UNIX_TIMESTAMP() - 120])
		or warn $DBI::errstr;

	# Clean up commands that exceeded their timeout limit directly in MySQL
	$dbh->do(qq[UPDATE command_queue SET `state` = 'timeout' WHERE `state` = 'sent' AND `timeout` > 0 AND `has_callback` = 1 AND UNIX_TIMESTAMP() - `unix_time` > `timeout`])
		or warn $DBI::errstr;
	$dbh->do(qq[DELETE FROM command_queue WHERE `state` = 'sent' AND `timeout` > 0 AND `has_callback` = 0 AND UNIX_TIMESTAMP() - `unix_time` > `timeout`])
		or warn $DBI::errstr;

	# Fetch next batch of 50 commands ready to send
	# Prioritize: 1. UI Commands (has_callback), 2. New Commands (sent_count=0)
	$sth = $dbh->prepare(qq[SELECT \
			command_queue.`id`, \
			command_queue.`serial`, \
			command_queue.`function`, \
			command_queue.`param`, \
			meters.`key` \
		FROM command_queue, meters \
		WHERE command_queue.`serial` = meters.`serial` \
		AND `state` = 'sent' \
		AND (command_queue.`unix_time` + (command_queue.`sent_count` * ] . DELAY_BETWEEN_RETRANSMIT . qq[)) <= UNIX_TIMESTAMP() \
		ORDER BY command_queue.`has_callback` DESC, IF(command_queue.`sent_count` = 0, 0, 1) ASC, command_queue.`function` ASC, command_queue.`unix_time` ASC \
		LIMIT 50 \
	]);
	$sth->execute or warn$DBI::errstr;

	while ($d = $sth->fetchrow_hashref) {
		$current_function = $d->{function};			

		if (defined $last_function && $current_function ne $last_function) {
			usleep(DELAY_BETWEEN_SERIALS * 1_000_000);
		}
		$last_function = $current_function;

		# send mqtt function to meter
		my $key = $d->{key};
		my $sha256 = sha256(pack('H*', $key));
		my $aes_key = substr($sha256, 0, 16);
		my $hmac_sha256_key = substr($sha256, 16, 16);
		log_info("send mqtt function " . $d->{function} . " to " . $d->{serial}, {-no_script_name => 1});
		
		my $topic = '/config/v2/' . $d->{serial} . '/' . time() . '/' . $d->{function};
		my $message = $d->{param} . "\0";
		my $iv = join('', map(chr(int rand(256)), 1..16));
		
		$message = $m->encrypt($message, $aes_key, $iv);$message = $iv . $message;
		my $hmac_sha256_hash = hmac_sha256($topic . $message, $hmac_sha256_key);
		$publish_mqtt->publish($topic =>$hmac_sha256_hash . $message);
		$dbh->do(qq[UPDATE command_queue SET `sent_count` = `sent_count` + 1 WHERE `id` = ?], undef, $d->{id})
			or warn $DBI::errstr;
		
		usleep(DELAY_BETWEEN_COMMAND_USEC);
	} 	 
	
	# wait and poll db again
	usleep(DB_POLL_DELAY_USEC);
}

# --- debug print helper ---
sub debug_print {
	my ($msg) = @_;
	print STDERR "$msg\n" if ($ENV{ENABLE_DEBUG} || '') =~ /^(1|true)$/i;
}

1;
