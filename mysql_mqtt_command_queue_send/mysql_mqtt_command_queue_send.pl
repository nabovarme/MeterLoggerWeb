#!/usr/bin/perl -w

use strict;
use warnings;
use Data::Dumper;
use Net::MQTT::Simple;
use DBI;
use Crypt::Mode::CBC;
use Digest::SHA qw(sha256 hmac_sha256);
use Config::Simple;
use Time::HiRes qw(usleep);

use lib qw(/etc/apache2/perl);
use Nabovarme::Db;

# --- Constants ---
use constant CONFIG_FILE                 => '/etc/Nabovarme.conf';
use constant DELAY_BETWEEN_RETRANSMIT    => 10;       # 10 second
use constant DELAY_BETWEEN_SERIALS       => 1;        # 1 second
use constant DB_POLL_DELAY               => 1;        # 1 second
use constant DELAY_BETWEEN_COMMAND_USEC  => 20_000;   # 20 mS

# --- Config ---
my $config = Config::Simple->new(CONFIG_FILE)
	or die Config::Simple->error();
my $mqtt_host = $config->param('mqtt_host');
my $mqtt_port = $config->param('mqtt_port');

# --- Globals ---
my ($dbh, $sth, $d);
my ($current_function, $last_function);

#print Dumper $pp->pidfile();

debug_print("starting...\n");

# --- MQTT publisher ---
my $publish_mqtt = Net::MQTT::Simple->new($mqtt_host . ':' . $mqtt_port);

# --- SIGINT handler ---
$SIG{INT} = sub {
	$publish_mqtt->disconnect();
	die "Interrupted\n";
};

# connect to db
if ($dbh = Nabovarme::Db->my_connect) {
	$dbh->{'mysql_auto_reconnect'} = 1;
	$dbh->{'mysql_enable_utf8'} = 0;	# get data as from queue as byte string
}
else {
	warn "cant't connect to db $!\n";
	die $!;
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
			debug_print("send mqtt function " . $d->{function} . " to " . $d->{serial} . "\n");
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
				debug_print("function " . $d->{function} . " to " . $d->{serial} . " timed out\n");
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
