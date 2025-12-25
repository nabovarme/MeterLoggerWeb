#!/usr/bin/perl -w

use strict;
use Data::Dumper;
use DBI;
use Config;
use Time::HiRes qw( usleep );

use Nabovarme::MQTT_RPC;

use constant RPC_TIMEOUT => 300;	# 5 minutes

$SIG{HUP} = \&get_version_and_status;
$SIG{USR1} = \&get_wifi_scan_results;

$SIG{INT} = \&sig_int_handler;

warn("starting...\n");

my $dbh;
my $sth;
my $d;

my $nabovarme_mqtt = new Nabovarme::MQTT_RPC;
$nabovarme_mqtt->connect() || die $!;

# connect to db
if ($dbh = Nabovarme::Db->my_connect) {
	$dbh->{'mysql_auto_reconnect'} = 1;
	warn("connected to db\n");
}
else {
	warn("cant't connect to db $!\n");
	die $!;
}

get_version_and_status();
while (1) {
	sleep 60;
}

# end of main

sub get_version_and_status {
	$sth = $dbh->prepare(qq[SELECT `type`, `serial`, `key` FROM meters WHERE `key` is not NULL AND `type` NOT LIKE 'aggregated']);
	$sth->execute;
	
	warn("send mqtt retain to all meters for version and status\n");
	while ($d = $sth->fetchrow_hashref) {
		warn("    send mqtt version, status and uptime commands to " . $d->{serial} . "\n");
		
		# send version
		$nabovarme_mqtt->call({	serial => $d->{serial},
								function => 'version',
								param => '1',
								callback => undef,
								timeout => RPC_TIMEOUT
							});
		
		unless ($d->{type} =~ /^electricity$/i) {
			# send status
			$nabovarme_mqtt->call({	serial => $d->{serial},
									function => 'status',
									param => '1',
									callback => undef,
									timeout => RPC_TIMEOUT
								});
		}

		# send uptime
		$nabovarme_mqtt->call({	serial => $d->{serial},
								function => 'uptime',
								param => '1',
								callback => undef,
								timeout => RPC_TIMEOUT
							});

		# send ssid
		$nabovarme_mqtt->call({	serial => $d->{serial},
								function => 'ssid',
								param => '1',
								callback => undef,
								timeout => RPC_TIMEOUT
							});

		# send rssi
		$nabovarme_mqtt->call({	serial => $d->{serial},
								function => 'rssi',
								param => '1',
								callback => undef,
								timeout => RPC_TIMEOUT
							});

		# send wifi_status
		$nabovarme_mqtt->call({	serial => $d->{serial},
								function => 'wifi_status',
								param => '1',
								callback => undef,
								timeout => RPC_TIMEOUT
							});

		# send ap_status
		$nabovarme_mqtt->call({	serial => $d->{serial},
								function => 'ap_status',
								param => '1',
								callback => undef,
								timeout => RPC_TIMEOUT
							});

		# send reset_reason
		$nabovarme_mqtt->call({	serial => $d->{serial},
								function => 'reset_reason',
								param => '1',
								callback => undef,
								timeout => RPC_TIMEOUT
							});
		# send network_quality
		$nabovarme_mqtt->call({	serial => $d->{serial},
								function => 'network_quality',
								param => '1',
								callback => undef,
								timeout => RPC_TIMEOUT
							});
	}
}

sub get_wifi_scan_results {
	$sth = $dbh->prepare(qq[SELECT `serial`, `key` FROM meters WHERE `key` is not NULL AND `type` NOT LIKE 'aggregated']);
	$sth->execute;
	
	warn("send mqtt scan command to all meters\n");
	while ($d = $sth->fetchrow_hashref) {
		warn("    send mqtt scan commands to " . $d->{serial} . "\n");

		$nabovarme_mqtt->call({	serial => $d->{serial},
								function => 'scan',
								param => '1',
								callback => undef,
								timeout => RPC_TIMEOUT
							});

		# send flash_id
		$nabovarme_mqtt->call({	serial => $d->{serial},
								function => 'flash_id',
								param => '1',
								callback => undef,
								timeout => RPC_TIMEOUT
							});

		# send flash_size
		$nabovarme_mqtt->call({	serial => $d->{serial},
								function => 'flash_size',
								param => '1',
								callback => undef,
								timeout => RPC_TIMEOUT
							});
	}
}

sub sig_int_handler {

	die $!;
}

1;
__END__