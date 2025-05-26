#!/usr/bin/perl -w

use strict;
use Data::Dumper;
use Net::MQTT::Simple;
use DBI;
use Crypt::Mode::CBC;
use Digest::SHA qw( sha256 hmac_sha256 );
use Config;
use Time::HiRes qw( usleep );

use lib qw( /etc/apache2/perl );
use lib qw( /opt/local/apache2/perl );
use lib qw( /Users/loppen/Documents/stoffer/MeterLoggerWeb/perl );
use lib qw( /Users/stoffer/src/esp8266/MeterLoggerWeb/perl );
use Nabovarme::Db;

use constant DELAY_BETWEEN_RETRANSMIT => 10_000_000;	# 10 second
use constant DELAY_BETWEEN_SERIALS => 1_000_000;		# 1 second
use constant DB_POLL_DELAY => 1_000_000;					# 1 second
use constant DELAY_BETWEEN_COMMAND => 20_000;	# 20 mS

$SIG{INT} = \&sig_int_handler;

use constant CONFIG_FILE => qw (/etc/Nabovarme.conf );

my $config = new Config::Simple(CONFIG_FILE) || die $!;
my $mqtt_host = $config->param('mqtt_host');
my $mqtt_port = $config->param('mqtt_port');

my $dbh;
my $sth;
my $d;

#print Dumper $pp->pidfile();

warn "starting...\n";

my $publish_mqtt = Net::MQTT::Simple->new($mqtt_host . ':' . $mqtt_port);

sub sig_int_handler {
	$publish_mqtt->disconnect();
	die $!;
}

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
$dbh->do(qq[DELETE FROM command_queue WHERE `state` = 'timeout']) or warn $!;

my ($current_function, $last_function);

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
		AND command_queue.`serial` LIKE meters.`serial` \
		AND `state` = 'sent' \
		ORDER BY `function` ASC, `unix_time` ASC \
	]);
	$sth->execute || warn $!;
	while ($d = $sth->fetchrow_hashref) {
		$current_function = $d->{function};			
		if ($current_function ne $last_function) {
			usleep(DELAY_BETWEEN_SERIALS);
		}

		if ($d->{unix_time} + $d->{sent_count} * (DELAY_BETWEEN_RETRANSMIT / 1_000_000) < time()) {
			# send mqtt function to meter
			my $key = $d->{key};
			my $sha256 = sha256(pack('H*', $key));
			my $aes_key = substr($sha256, 0, 16);
			my $hmac_sha256_key = substr($sha256, 16, 16);
			warn "send mqtt function " . $d->{function} . " to " . $d->{serial} . "\n";
			my $topic = '/config/v2/' . $d->{serial} . '/' . time() . '/' . $d->{function};
			my $message = $d->{param} . "\0";
			my $iv = join('', map(chr(int rand(256)), 1..16));
			$message = $m->encrypt($message, $aes_key, $iv);
			$message = $iv . $message;
			my $hmac_sha256_hash = hmac_sha256($topic . $message, $hmac_sha256_key);
			
			$publish_mqtt->publish($topic => $hmac_sha256_hash . $message);
			$dbh->do(qq[UPDATE command_queue SET \
				`sent_count` = `sent_count` + 1 \
				WHERE `id` = ] . $d->{id}) or warn $!;
			
			usleep(DELAY_BETWEEN_COMMAND);
		}
		
		# remove timed out calls from db
		if ($d->{timeout}) {
			if (time() - $d->{unix_time} > $d->{timeout}) {
				warn "function " . $d->{function} . " to " . $d->{serial} . " timed out\n";
				if ($d->{has_callback}) {
					$dbh->do(qq[UPDATE command_queue SET \
						`state` = 'timeout' \
						WHERE `id` = ] . $d->{id}) or warn $!;
				}
				else {
					$dbh->do(qq[DELETE FROM command_queue WHERE `id` = ] . $d->{id});
				}
			}
		}
		
		$last_function = $current_function;
	} 	   
	# wait and retransmit     
#	usleep(DELAY_BETWEEN_RETRANSMIT);
	usleep(DB_POLL_DELAY);
}               


1;

__END__
