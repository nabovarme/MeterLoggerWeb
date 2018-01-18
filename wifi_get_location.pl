#!/usr/bin/perl -w

use strict;
use Data::Dumper;
use LWP::UserAgent;
use JSON::Create 'create_json';
use JSON::Parse 'parse_json';

#use lib qw( /opt/local/apache2/perl/ );
use lib qw( /etc/apache2/perl );
use Nabovarme::Db;


my $api_key = '';
my $url = 'https://www.googleapis.com/geolocation/v1/geolocate?key=';

my $dbh;
my ($sth, $sth2);
my ($d, $d2);


if ($dbh = Nabovarme::Db->my_connect) {
	$dbh->{'mysql_auto_reconnect'} = 1;
    $sth = $dbh->prepare(qq[SELECT `serial`, `info` FROM meters]);
    $sth->execute || warn $!;
	if ($sth->rows) {
		while ($d = $sth->fetchrow_hashref) {
			my $nested = {	considerIp => 'false',
							wifiAccessPoints => []
						};
			my $quoted_serial = $dbh->quote($d->{serial});
			my $sth2 = $dbh->prepare(qq[SELECT `serial`, `ssid`, `bssid`, `rssi`, `channel`, `unix_time` from wifi_scan where `serial` like ] . $quoted_serial . 
									qq[ AND FROM_UNIXTIME(`unix_time`) > NOW() - INTERVAL 3 DAY GROUP BY `bssid` ORDER BY `unix_time`]);
			$sth2->execute || warn $!;
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
					print $loc->{'location'}->{'lat'} . ',' . $loc->{'location'}->{'lng'} . ',' . '"' . $d->{'serial'} . ' ' . $d->{'info'} . '"' . "\n";
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
