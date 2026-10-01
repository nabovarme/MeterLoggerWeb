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
	$dbh->{'mysql_enable_utf8'} = 0;
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
	$dbh->do(qq[UPDATE command_queue \
		SET `state` = 'timeout' \
		WHERE `state` = 'sent' \
			AND `timeout` > 0 \
			AND `has_callback` = 1 \
			AND UNIX_TIMESTAMP() - `unix_time` > `timeout` \
	]) or warn $DBI::errstr;

	$dbh->do(qq[DELETE FROM command_queue \
		WHERE `state` = 'sent' \
			AND `timeout` > 0 \
			AND `has_callback` = 0 \
			AND UNIX_TIMESTAMP() - `unix_time` > `timeout` \
	]) or warn $DBI::errstr;

	# Clean up ALL duplicate commands per meter (both stateful and stateless)
	# (except cron which can have multiple valid overlapping commands)
	$dbh->do(qq[DELETE c1 FROM command_queue c1 \
		JOIN command_queue c2 \
			ON c1.serial = c2.serial AND c1.function = c2.function \
		WHERE c1.state = 'sent' \
			AND c2.state = 'sent' \
			AND c1.id < c2.id \
			AND c1.function NOT IN ('set_cron', 'clear_cron') \
	]) or warn $DBI::errstr;

	# Fetch pending commands eligible for transmission/retransmission
	$sth = $dbh->prepare(qq[SELECT \
			command_queue.`id`, \
			command_queue.`serial`, \
			command_queue.`function`, \
			command_queue.`param`, \
			command_queue.`is_stateful`, \
			meters.`key` \
		FROM command_queue, meters \
		WHERE command_queue.`serial` = meters.`serial` \
		AND `state` = 'sent' \
		AND (command_queue.`unix_time` + (command_queue.`sent_count` * ] . DELAY_BETWEEN_RETRANSMIT . qq[)) <= UNIX_TIMESTAMP() \
		ORDER BY command_queue.`has_callback` DESC, IF(command_queue.`sent_count` = 0, 0, 1) ASC, command_queue.`function` ASC, command_queue.`unix_time` ASC \
	]);
	$sth->execute or warn$DBI::errstr;

	my %sent_this_batch;

	while ($d = $sth->fetchrow_hashref) {
		$current_function = $d->{function};
		my $is_stateful = $d->{is_stateful};

		if (!$is_stateful) {
			my $dedup_key = $d->{serial} . '-' . $current_function;
			next if $sent_this_batch{$dedup_key};
			$sent_this_batch{$dedup_key} = 1;
		}

		if (defined $last_function && $current_function ne$last_function) {
			usleep(DELAY_BETWEEN_SERIALS * 1_000_000);
		}
		$last_function = $current_function;

		# send mqtt function to meter
		my $key = $d->{key};
		my $sha256 = sha256(pack('H*', $key));
		my $aes_key = substr($sha256, 0, 16);
		my $hmac_sha256_key = substr($sha256, 16, 16);
		log_info("send mqtt function " . $current_function . " to " . $d->{serial}, {-no_script_name => 1});
		
		my $topic = '/config/v2/' . $d->{serial} . '/' . time() . '/' . $current_function;
		my $message = $d->{param} . "\0";
		my $iv = join('', map(chr(int rand(256)), 1..16));
		
		$message = $m->encrypt($message, $aes_key, $iv);
		$message = $iv . $message;
		my $hmac_sha256_hash = hmac_sha256($topic . $message, $hmac_sha256_key);
		
		$publish_mqtt->publish($topic => $hmac_sha256_hash . $message);
		
		if ($is_stateful) {$dbh->do(qq[UPDATE command_queue \
				SET `sent_count` = `sent_count` + 1 \
				WHERE `id` = ?], undef, $d->{id}
			) or warn $DBI::errstr;
		} else {
			$dbh->do(qq[UPDATE command_queue \
				SET `sent_count` = `sent_count` + 1 \
				WHERE `serial` = ? \
					AND `function` = ? \
					AND `state` = 'sent'], undef, $d->{serial}, $current_function
			) or warn $DBI::errstr;
		}
		
		usleep(DELAY_BETWEEN_COMMAND_USEC);
	}
	
	# wait and poll db again
	usleep(DB_POLL_DELAY_USEC);
}
1;
