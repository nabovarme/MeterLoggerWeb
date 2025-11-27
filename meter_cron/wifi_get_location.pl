#!/usr/bin/perl -w

use strict;
use warnings;
use Data::Dumper;
use LWP::UserAgent;
use JSON::Create 'create_json';
use JSON::Parse 'parse_json';
use Config::Simple;

# Add the required libraries to the Perl search path
use lib qw( /etc/apache2/perl );

use Nabovarme::Db;

use constant CONFIG_FILE => '/etc/Nabovarme.conf';

# Load configuration
print "Loading configuration from " . CONFIG_FILE . "\n";
my $config = new Config::Simple(CONFIG_FILE) || die "ERROR: Failed to load config: $!\n";
my $api_key = $config->param('google_api_key');
my $url = $config->param('google_geolocation_api_url');

# Database connection
print "Connecting to the database...\n";
my $dbh = Nabovarme::Db->my_connect;
$dbh->{'mysql_auto_reconnect'} = 1;

# Main processing
print "Processing meters...\n";
process_meters($dbh);

sub process_meters {
	my ($dbh) = @_;
	my $sth;

	# Fetch meters
	if ($ARGV[0]) {
			$sth = $dbh->prepare(qq[
				SELECT `serial`, `info`
				FROM meters
				WHERE `serial` LIKE ] . $dbh->quote($ARGV[0])
			);
	}
	else {
		$sth = $dbh->prepare(qq[SELECT `serial`, `info` FROM meters]);
	}

	$sth->execute || die $!;
	
	if ($sth->rows) {
		while (my $meter = $sth->fetchrow_hashref) {
			print "Processing meter: $meter->{serial}\n";

			my $wifi_data = fetch_wifi_data($dbh, $meter->{serial});
			
			if ($wifi_data) {
				print "Fetched WiFi data for meter $meter->{serial}\n";
				my $location = get_location($wifi_data);
				
				if ($location) {
					print "Location found for meter $meter->{serial}: $location->{lat}, $location->{lng}\n";
					update_meter_location($dbh, $meter->{serial}, $location);
				} else {
					print "WARN: No location found for meter $meter->{serial}\n";
				}
			} else {
				print "WARN: No WiFi data found for meter $meter->{serial}\n";
			}
		}
	}
}

sub fetch_wifi_data {
	my ($dbh, $serial) = @_;
	my $quoted_serial = $dbh->quote($serial);
	
	print "Fetching WiFi data for meter $serial\n";
	my $sth = $dbh->prepare(qq[SELECT `serial`, `ssid`, `bssid`, `rssi`, `channel`, `unix_time`
		FROM wifi_scan where `serial` LIKE $quoted_serial
		AND FROM_UNIXTIME(`unix_time`) > NOW() - INTERVAL 3 DAY
		GROUP BY `bssid` ORDER BY `unix_time`
	]);
	$sth->execute || warn "$!\n";
	if ($sth->rows) {
		my @wifi_data;
		while (my $wifi = $sth->fetchrow_hashref) {
			push @wifi_data, {
				macAddress	  => $wifi->{bssid},
				signalStrength  => $wifi->{rssi},
				channel		 => $wifi->{channel},
			};
		}
		return \@wifi_data;
	}
	else {
		return undef;
	}
}

sub get_location {
	my ($wifi_data) = @_;
	
	print "Requesting geolocation...\n";
	my $request_data = {
		considerIp		=> 'false',
		wifiAccessPoints  => $wifi_data
	};
	
	my $json_request = create_json($request_data);
	my $response = send_geolocation_request($json_request);
	
	return parse_location_response($response) if $response;
	print "WARN: Failed to get location data from geolocation service\n";
	return;
}

sub send_geolocation_request {
	my ($json_request) = @_;
	
	print "Sending geolocation request...\n";
	my $req = HTTP::Request->new(POST => $url . $api_key);
	$req->content($json_request);
	$req->header('content-type' => 'application/json');
	
	my $ua = LWP::UserAgent->new;
	my $response = $ua->request($req);
	
	if ($response->is_success) {
		print "Geolocation request successful\n";
		return $response;
	} else {
		print "ERROR: Geolocation request failed: " . $response->status_line . "\n";
		return undef;
	}
}

sub parse_location_response {
	my ($response) = @_;
	
	print "Parsing location response...\n";
	my $location_data = parse_json($response->decoded_content);
	
	if ($location_data->{location}) {
		return $location_data->{location};
	} else {
		print "WARN: Location data missing in response\n";
		return undef;
	}
}

sub update_meter_location {
	my ($dbh, $serial, $location) = @_;
	
	print "Updating location for meter $serial in database...\n";
	my $lat = $dbh->quote($location->{lat});
	my $lng = $dbh->quote($location->{lng});
	my $quoted_serial = $dbh->quote($serial);
	
	my $update_query = qq[
		UPDATE meters 
		SET `location_lat` = $lat, `location_long` = $lng 
		WHERE `serial` = $quoted_serial
	];
	
	if ($dbh->do($update_query)) {
		print "Successfully updated location for meter $serial\n";
	} else {
		print "ERROR: Failed to update location for meter $serial: $!\n";
	}
}

__END__
