#!/usr/bin/perl -w

use strict;
use warnings;
use Data::Dumper;
use Net::MQTT::Simple;
use DBI;
use Crypt::Mode::CBC;
use Digest::SHA qw(sha256 hmac_sha256);
use Time::HiRes qw(time);
use Mojo::IOLoop;

use Nabovarme::Db;
use Nabovarme::Utils;

# --- Constants ---
use constant DELAY_BETWEEN_RETRANSMIT   => 10;       # Retransmit every 10 seconds
use constant MIN_METER_COMMAND_INTERVAL => 1.0;      # 1.0s minimum gap between commands to the SAME meter
use constant DB_POLL_INTERVAL_SEC       => 1.0;      # Poll DB every 1 second
use constant COMMAND_OFFSET_INTERVAL    => 0.02;     # 20ms offset to pace concurrent dispatches

# --- Config from environment ---
my $mqtt_host = $ENV{'MQTT_HOST'}
	or log_die("ERROR: MQTT_HOST environment variable not set", {-no_script_name => 1});

my $mqtt_port = $ENV{'MQTT_PORT'}
	or log_die("ERROR: MQTT_PORT environment variable not set", {-no_script_name => 1});

# --- Globals ---
my ($dbh, $sth);
my %in_flight;               # Tracks command IDs currently scheduled in Mojo timer queue
my %meter_last_sent_time;    # Tracks last sent timestamp per meter serial: $meter_last_sent_time{$serial}

log_info("starting per-meter throttled async dispatcher...", {-no_script_name => 1});

# --- MQTT publisher ---
my $publish_mqtt = Net::MQTT::Simple->new($mqtt_host . ':' . $mqtt_port);

# --- SIGINT handler ---
$SIG{INT} = sub {
	$publish_mqtt->disconnect();
	log_die("Interrupted", {-no_script_name => 1});
};

# --- Connect to DB ---
if ($dbh = Nabovarme::Db->my_connect) {
	$dbh->{'mysql_auto_reconnect'} = 1;
	$dbh->{'mysql_enable_utf8'} = 0;
}
else {
	log_die("cant't connect to db $!", {-no_script_name => 1});
}

my $m = Crypt::Mode::CBC->new('AES');

# --------------------------------------------------
# Cleanup Routine (Runs every 10 seconds)
# --------------------------------------------------
Mojo::IOLoop->recurring(10 => sub {
	$dbh->do(qq[DELETE FROM command_queue WHERE `state` = 'timeout'])
		or warn $DBI::errstr;
	$dbh->do(qq[DELETE FROM command_queue WHERE `state` = 'received' AND `unix_time` < UNIX_TIMESTAMP() - 120])
		or warn $DBI::errstr;

	# Timeouts are still correctly calculated based on original unix_time
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

	# Prune duplicate commands per meter
	# Transfer sent_count and last_sent to the newer duplicate before pruning
	$dbh->do(qq[UPDATE command_queue c1 \
		JOIN command_queue c2 \
			ON c1.serial = c2.serial AND c1.function = c2.function \
		SET c2.sent_count = GREATEST(c1.sent_count, c2.sent_count), \
		    c2.last_sent = GREATEST(c1.last_sent, c2.last_sent) \
		WHERE c1.state = 'sent' \
			AND c2.state = 'sent' \
			AND c1.id < c2.id \
			AND c1.function NOT IN ('set_cron', 'clear_cron') \
	]) or warn $DBI::errstr;

	# Prune duplicate commands per meter (deletes the older ones)
	$dbh->do(qq[DELETE c1 FROM command_queue c1 \
		JOIN command_queue c2 \
			ON c1.serial = c2.serial AND c1.function = c2.function \
		WHERE c1.state = 'sent' \
		AND c2.state = 'sent' \
		AND c1.id < c2.id \
		AND c1.function NOT IN ('set_cron', 'clear_cron') \
	]) or warn$DBI::errstr;
});

# --------------------------------------------------
# Event-Driven Dispatcher Routine
# --------------------------------------------------
sub process_queue {
	# Use prepare_cached so Perl only compiles this SQL query once
	$sth = $dbh->prepare_cached(qq[SELECT \
			command_queue.`id`, \
			command_queue.`serial`, \
			command_queue.`function`, \
			command_queue.`param`, \
			command_queue.`is_stateful`, \
			meters.`key` \
		FROM command_queue, meters \
		WHERE command_queue.`serial` = meters.`serial` \
		AND `state` = 'sent' \
		AND (command_queue.`last_sent` = 0 OR command_queue.`last_sent` + ] . DELAY_BETWEEN_RETRANSMIT . qq[ <= UNIX_TIMESTAMP()) \
		ORDER BY command_queue.`has_callback` DESC, IF(command_queue.`sent_count` = 0, 0, 1) ASC, command_queue.`unix_time` ASC \
	]);
	$sth->execute or warn $DBI::errstr;

	# Prepare UPDATE statements ONCE in memory instead of compiling them on every loop iteration
	my $sth_update_stateful = $dbh->prepare_cached(qq[
		UPDATE command_queue \
			SET `sent_count` = `sent_count` + 1, \
			    `last_sent` = UNIX_TIMESTAMP() \
			WHERE `id` = ? \
	]);
	
	my $sth_update_stateless = $dbh->prepare_cached(qq[
		UPDATE command_queue \
			SET `sent_count` = `sent_count` + 1, \
			    `last_sent` = UNIX_TIMESTAMP() \
			WHERE `serial` = ? \
				AND `function` = ? \
				AND `state` = 'sent' \
	]);

	my %sent_this_pass;
	my $now = time();
	my $dispatch_offset = 0;

	while (my $d = $sth->fetchrow_hashref) {
		my $cmd_id           = $d->{id};
		my $serial           = $d->{serial};
		my $current_function = $d->{function};
		my $is_stateful      = $d->{is_stateful};

		# Skip if this command ID is already queued in an active timer
		next if $in_flight{$cmd_id};

		# Deduplicate stateless commands within the same pass
		if (!$is_stateful) {
			my $dedup_key = $serial . '-' . $current_function;
			next if $sent_this_pass{$dedup_key};
			$sent_this_pass{$dedup_key} = 1;
		}

		# Calculate required delay for THIS specific meter
		my $last_sent = $meter_last_sent_time{$serial} // 0;
		my $time_since_last_sent = $now - $last_sent;
		my $delay = 0;
		
		if ($time_since_last_sent < MIN_METER_COMMAND_INTERVAL) {
			# Meter received a command recently -> delay to preserve per-meter processing window
			$delay = MIN_METER_COMMAND_INTERVAL - $time_since_last_sent;
		} else {
			# Add offset to pace transmissions and avoid socket bursts
			$delay = $dispatch_offset;
			$dispatch_offset += COMMAND_OFFSET_INTERVAL;
		}

		# Mark projected send time and in-flight status IMMEDIATELY
		$meter_last_sent_time{$serial} = $now +$delay;
		$in_flight{$cmd_id} = 1;

		# Execute the pre-compiled statements (Uses a fraction of the CPU)
		if ($is_stateful) {
			$sth_update_stateful->execute($cmd_id) or warn $DBI::errstr;
		}
		else {
			$sth_update_stateless->execute($serial, $current_function) or warn $DBI::errstr;
		}

		# Schedule asynchronous MQTT transmission
		Mojo::IOLoop->timer($delay => sub {
			my $key = $d->{key};
			my $sha256 = sha256(pack('H*', $key));
			my $aes_key = substr($sha256, 0, 16);
			my $hmac_sha256_key = substr($sha256, 16, 16);

			log_debug("send mqtt function " . $current_function . " to " . $serial, {-no_script_name => 1});
			
			my $topic = '/config/v2/' . $serial . '/' . time() . '/' . $current_function;
			my $message = $d->{param} . "\0";
			my $iv = join('', map(chr(int rand(256)), 1..16));
			
			$message = $m->encrypt($message, $aes_key, $iv);
			$message = $iv . $message;
			my $hmac_sha256_hash = hmac_sha256($topic . $message, $hmac_sha256_key);
			
			$publish_mqtt->publish($topic => $hmac_sha256_hash . $message);

			# Release in-flight flag after transmission finishes
			delete $in_flight{$cmd_id};
		});
	}
}

# --------------------------------------------------
# Main Event Loop
# --------------------------------------------------
Mojo::IOLoop->recurring(DB_POLL_INTERVAL_SEC => \&process_queue);
Mojo::IOLoop->start;

1;
