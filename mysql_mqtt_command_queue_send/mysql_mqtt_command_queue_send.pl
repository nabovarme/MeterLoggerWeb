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
use constant DELAY_BETWEEN_RETRANSMIT    => 10;       # 10 second
use constant DELAY_BETWEEN_SERIALS       => 1;        # 1 second
use constant DB_POLL_DELAY               => 1;        # 1 second
use constant DELAY_BETWEEN_COMMAND_USEC  => 20_000;   # 20 mS

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

# delete commands timed out
$dbh->do(qq[DELETE FROM command_queue WHERE `state` = 'timeout']) or warn $DBI::errstr;

while (1) {
	$sth = $dbh->prepare(qq[SELECT \
			command_queue.`id`, \
			command_queue.`serial`, \
			command_queue.`function`, \
			command_queue.`param`, \
			command_queue.`unix_time`, \
			command_queue.`has_callback`, \
			command_queue.`timeout`, \
			command_queue.`sent_count`, \
			meters.`key` \
		FROM command_queue, meters \
		WHERE FROM_UNIXTIME(`unix_time`) <= NOW() \
		AND command_queue.`serial` = meters.`serial` \
		AND `state` = 'sent' \
		ORDER BY `function` ASC, `unix_time` ASC \
	]);
	$sth->execute || warn $DBI::errstr;

	while ($d = $sth->fetchrow_hashref) {
		$current_function = $d->{function};			

		if ($current_function ne $last_function) {
			usleep(DELAY_BETWEEN_SERIALS * 1_000_000);
		}

		if ($d->{unix_time} + $d->{sent_count} * DELAY_BETWEEN_RETRANSMIT < time()) {
			# send mqtt function to meter
			my $key = $d->{key};
			my $sha256 = sha256(pack('H*', $key));
			my $aes_key = substr($sha256, 0, 16);
			my $hmac_sha256_key = substr($sha256, 16, 16);
			log_info("send mqtt function " . $d->{function} . " to " . $d->{serial}, {-no_script_name => 1});
			my $topic = '/config/v2/' . $d->{serial} . '/' . time() . '/' . $d->{function};
			my $message = $d->{param} . "\0";
			my $iv = join('', map(chr(int rand(256)), 1..16));
			$message = $m->encrypt($message, $aes_key, $iv);
			$message = $iv . $message;
			my $hmac_sha256_hash = hmac_sha256($topic . $message, $hmac_sha256_key);
			
			$publish_mqtt->publish($topic => $hmac_sha256_hash . $message);
			$dbh->do(qq[UPDATE command_queue SET `sent_count` = `sent_count` + 1 WHERE `id` = ?], undef, $d->{id})
				or warn $DBI::errstr;
			
			usleep(DELAY_BETWEEN_COMMAND_USEC);
		}
		
		# remove timed out calls from db
		if ($d->{timeout}) {
			if (time() - $d->{unix_time} > $d->{timeout}) {
				log_warn("function " . $d->{function} . " to " . $d->{serial} . " timed out", {-no_script_name => 1});
				if ($d->{has_callback}) {
					$dbh->do(qq[UPDATE command_queue SET `state` = 'timeout' WHERE `id` = ?], undef, $d->{id})
						or warn $DBI::errstr;
				}
				else {
					$dbh->do(qq[DELETE FROM command_queue WHERE `id` = ?], undef, $d->{id})
						or warn $DBI::errstr;
				}
			}
		}
		
		$last_function = $current_function;
	} 	   
	
	# wait and retransmit     
#	usleep(DELAY_BETWEEN_RETRANSMIT);
	usleep(DB_POLL_DELAY * 1_000_000);
}

# --- debug print helper ---
sub debug_print {
	my ($msg) = @_;
	print STDERR "$msg\n" if ($ENV{ENABLE_DEBUG} || '') =~ /^(1|true)$/i;
}

1;

__END__
