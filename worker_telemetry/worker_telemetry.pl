#!/usr/bin/perl -w

use strict;
use warnings;
use Redis;
use DBI;
use Storable qw(thaw);

use Nabovarme::Db;
use Nabovarme::Crypto;
use Nabovarme::Utils;

# Set signal handler for clean manual worker termination
$SIG{INT} = sub { log_info("Caught SIGINT, exiting.", {-no_script_name => 1}); exit 0; };

my $redis_host =$ENV{'REDIS_HOST'} or log_die("ERROR: REDIS_HOST not set");
my $redis_port =$ENV{'REDIS_PORT'} or log_die("ERROR: REDIS_PORT not set");
my $redis = Redis->new(server => "$redis_host:$redis_port", reconnect => 60);

my $dbh = Nabovarme::Db->my_connect or log_die("Cant't connect to DB $!");
$dbh->{'mysql_auto_reconnect'} = 1;

my $crypto = new Nabovarme::Crypto;

log_info("Starting Telemetry Worker...", {-no_script_name => 1});

while (1) {
	my ($q, $payload) =$redis->blpop('mqtt:queue:telemetry', 86400);
	next unless $payload;
	
	unless ($dbh &&$dbh->ping) {
		log_die("Database connection lost. Exiting for Docker to restart.", {-no_script_name => 1});
	}

	my $data = thaw($payload);
	my ($topic,$message) = ($data->{topic},$data->{message});
	
	my ($meter_serial, $unix_time) =$topic =~ m!/sample/v\d+/([^/]+)/(\d+)!;
	next unless $meter_serial;

	my $sample = $crypto->decrypt_topic_message_for_serial($topic, $message,$meter_serial);
	if (defined $sample) {	
		$sample =~ s/&$//;
		my %mq;
		foreach my $kv (split(/&/,$sample)) {
			if (my ($key,$val, $unit) =$kv =~ /([^=]*)=(\S+)(?:\s+(.*))?/) {
				if ($key =~ /^e1$/i && defined $unit) {$val *= 1000 if $unit =~ /^MWh$/i;
					$val *= 277.77777777778 if $unit =~ /^Gj$/i;
				}
				$mq{$key} =$val;
			}
		}
		
		my $sth =$dbh->prepare(qq[INSERT INTO `samples` (`serial`,`heap`,`flow_temp`,`return_flow_temp`,`temp_diff`,`t3`,`flow`,`effect`,`hours`,`volume`,`energy`,`unix_time`) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)]);
		$sth->execute($meter_serial,$mq{heap}, $mq{t1},$mq{t2}, $mq{tdif},$mq{t3}, $mq{flow1},$mq{effect1}, $mq{hr},$mq{v1}, $mq{e1},$unix_time);
		
		if ($sth->err) {
			log_warn($sth->errstr, {-no_script_name => 1});
			# Rollback to queue
			$redis->rpush('mqtt:queue:telemetry',$payload);
		} else {
			$dbh->do(qq[UPDATE meters SET last_updated = ? WHERE serial = ? AND ? > last_updated], undef, $unix_time, $meter_serial,$unix_time);
			log_info("$topic$sample", {-no_script_name => 1});			
		}
	} else {
		log_warn("$topic hmac error", {-no_script_name => 1});
	}
}
