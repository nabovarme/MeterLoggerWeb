#!/usr/bin/perl -w

use strict;
use warnings;
use Redis;
use DBI;
use Storable qw(thaw);
use Encode qw(decode encode FB_DEFAULT);

use Nabovarme::Db;
use Nabovarme::Crypto;
use Nabovarme::Utils;

$SIG{INT} = sub { log_info("Caught SIGINT, exiting.", {-no_script_name => 1}); exit 0; };

my $redis_host =$ENV{'REDIS_HOST'} or log_die("ERROR: REDIS_HOST not set");
my $redis_port =$ENV{'REDIS_PORT'} or log_die("ERROR: REDIS_PORT not set");
my $redis = Redis->new(server => "$redis_host:$redis_port", reconnect => 60);

my $dbh = Nabovarme::Db->my_connect or log_die("Cant't connect to DB $!");
$dbh->{'mysql_auto_reconnect'} = 1;

my $crypto = new Nabovarme::Crypto;

my %STATUS_FIELDS = (
	'version'         => 'sw_version',
	'status'          => 'valve_status',
	'uptime'          => 'uptime',
	'ssid'            => 'ssid',
	'rssi'            => 'rssi',
	'wifi_status'     => 'wifi_status',
	'ap_status'       => 'ap_status',
	'set_ap_mesh_pwd' => 'mesh_pwd',
	'chip_id'         => 'chip_id',
	'flash_id'        => 'flash_id',
	'flash_size'      => 'flash_size',
	'vdd'             => 'vdd',
	'mem'             => 'mem'
);

my %LOG_EVENTS = (
	'flash_error'       => 'flash_error',
	'reset_reason'      => 'reset_reason',
	'cnx_csa_fn_called' => 'cnx_csa_fn_called'
);

log_info("Starting Syslog Worker...", {-no_script_name => 1});

# Safe translation wrapper formatting SSID byte strings to clean internal UTF-8
sub decode_ssid {
	my ($raw) = @_;
	return undef unless defined $raw;
	my $ssid = decode('UTF-8', $raw, Encode::FB_DEFAULT);$ssid =~ s/[\x00-\x1F\x7F]//g;
	return $ssid;
}

while (1) {
	my ($q, $payload) =$redis->blpop('mqtt:queue:syslog', 86400);
	next unless $payload;

	unless ($dbh &&$dbh->ping) {
		log_die("Database connection lost. Exiting for Docker to restart.", {-no_script_name => 1});
	}
	
	my $data = thaw($payload);
	my ($topic,$message) = ($data->{topic},$data->{message});
	my ($function,$meter_serial, $unix_time) =$topic =~ m!/([^/]+)/v\d+/([^/]+)(?:/(\d+))?!;
	next unless $meter_serial;

	# --- Special Case: Offline has no payload ---
	if ($function eq 'offline') {
		$unix_time //= time();$dbh->do(qq[INSERT INTO `log` (`serial`, `function`, `unix_time`) VALUES (?, 'offline', ?)], undef, $meter_serial,$unix_time);
		log_warn("$topic\toffline", {-no_script_name => 1});
		next;
	}

	my $cleartext = $crypto->decrypt_topic_message_for_serial($topic, $message,$meter_serial);
	next unless defined $cleartext;
	$cleartext =~ s/[\x00\s]+$//;

	# --- Clean Dispatch Table Routing ---
	if (exists $STATUS_FIELDS{$function}) {$dbh->do(qq[UPDATE meters SET $STATUS_FIELDS{$function} = ? WHERE serial = ?], undef, $cleartext,$meter_serial);
		log_info("$topic\t$cleartext", {-no_script_name => 1});
	}
	elsif (exists $LOG_EVENTS{$function}) {$dbh->do(qq[INSERT INTO `log` (`serial`, `function`, `param`, `unix_time`) VALUES (?, ?, ?, ?)], undef, $meter_serial, $LOG_EVENTS{$function}, $cleartext,$unix_time);
		log_info("$topic\t$cleartext", {-no_script_name => 1});
	}
	elsif ($function eq 'network_quality') {
		$cleartext =~ s/&$//;
		my %mq = $cleartext =~ /([^=]*)=(.*?)(?:&|$)/g;
		$dbh->do(qq[UPDATE meters SET ping_response_time=?, ping_average_packet_loss=?, disconnect_count=? WHERE serial=?], undef, $mq{ping_response_time},$mq{ping_average_packet_loss}, $mq{disconnect_count},$meter_serial);
		log_info("$topic\t$cleartext", {-no_script_name => 1});
	}
	elsif ($function eq 'scan_result') {
		$cleartext =~ s/&$//;
		my %mq = $cleartext =~ /([^=]*)=(.*?)(?:&|$)/g;
		
		# Safety Truncation Check to prevent DB column sizing overflows
		$mq{ssid} = substr($mq{ssid} || '', 0, 64);
		my $ssid_utf8 = decode_ssid($mq{ssid});
		$ssid_utf8 = substr($ssid_utf8, 0, 64) if defined $ssid_utf8 && length($ssid_utf8) > 64;
		
		my $sth =$dbh->prepare(qq[INSERT INTO `wifi_scan` (`serial`,`ssid_raw`,`ssid`,`bssid`,`rssi`,`channel`,`auth_mode`,`pairwise_cipher`,`group_cipher`,`phy_11b`,`phy_11g`,`phy_11n`,`wps`,`unix_time`) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,UNIX_TIMESTAMP())]);
		$sth->execute($meter_serial, $mq{ssid},$ssid_utf8, $mq{bssid},$mq{rssi}, $mq{channel},$mq{auth_mode}, $mq{pairwise_cipher},$mq{group_cipher}, $mq{phy_11b},$mq{phy_11g}, $mq{phy_11n},$mq{wps});
		
		if ($sth->err) {
			log_warn($sth->errstr, {-no_script_name => 1});
			$redis->rpush('mqtt:queue:syslog',$payload);
		} else {
			log_info("$topic\t$cleartext", {-no_script_name => 1});
		}
	}
}
