#!/usr/bin/perl -w

use strict;
use Data::Dumper;
use LWP::UserAgent;
use JSON::Create 'create_json';
use JSON::Parse 'parse_json';

use lib qw( /opt/local/apache2/perl/ );
use lib qw( /etc/apache2/perl );
use Nabovarme::Db;

use constant CONFIG_FILE => '/etc/Nabovarme.conf';

my $config = new Config::Simple(CONFIG_FILE) || die $!;

my $api_key = $config->param('google_api_key');
my $url = $config->param('google_geolocation_api_url');

my $dbh;
my ($sth, $sth2);
my ($d, $d2);


if ($dbh = Nabovarme::Db->my_connect) {
	$dbh->{'mysql_auto_reconnect'} = 1;
	if ($ARGV[0]) {
		$sth = $dbh->prepare(qq[SELECT `serial`, `info` FROM meters WHERE `serial` LIKE ] . $dbh->quote($ARGV[0]));
	}
	else {
		$sth = $dbh->prepare(qq[SELECT `serial`, `info` FROM meters]);
	}
	$sth->execute || warn "$!\n";
	if ($sth->rows) {
		while ($d = $sth->fetchrow_hashref) {
			my $nested = {	considerIp => 'false',
							wifiAccessPoints => []
						};
			my $quoted_serial = $dbh->quote($d->{serial});
			my $sth2 = $dbh->prepare(qq[SELECT `serial`, `ssid`, `bssid`, `rssi`, `channel`, `unix_time` from wifi_scan where `serial` LIKE ] . $quoted_serial . 
									qq[ AND FROM_UNIXTIME(`unix_time`) > NOW() - INTERVAL 3 DAY GROUP BY `bssid` ORDER BY `unix_time`]);
			$sth2->execute || warn "$!\n";
			if ($sth2->rows) {
				# create data structure for json request
				while ($d2 = $sth2->fetchrow_hashref) {
					push @{$nested->{'wifiAccessPoints'}}, {'macAddress' => $d2->{'bssid'}, 'signalStrength' => $d2->{'rssi'}, 'channel' => $d2->{'channel'} };
				}
#				print Dumper $d->{serial};
				my $json = create_json($nested);

				# send request
				my $req = HTTP::Request->new();
				$req->method('POST');
				$req->uri($url . $api_key);
				$req->content($json);
				$req->header('content-type' => 'application/json');

				my $ua = new LWP::UserAgent();
				my $response = $ua->request($req);

				if ($response->is_success() ) {
#					print $response->decoded_content();
					my $loc = parse_json($response->decoded_content());
					
					# insert into db
					my $quoted_lat = $dbh->quote($loc->{'location'}->{'lat'});
					my $quoted_long = $dbh->quote($loc->{'location'}->{'lng'});
					$dbh->do(qq[UPDATE meters SET `location_lat` = $quoted_lat, `location_long` = $quoted_long WHERE `serial` LIKE $quoted_serial]) or warn "$!\n";
#					print $loc->{'location'}->{'lat'} . ',' . $loc->{'location'}->{'lng'} . ',' . '"' . $d->{'serial'} . ' ' . $d->{'info'} . '"' . "\n";
				}
				else {
					print("ERROR: " . $response->status_line()) . "\n";
					print $response->decoded_content();
				}
			}
		}
	}        
}

1;

__END__
