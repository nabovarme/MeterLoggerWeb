#!/usr/bin/perl -w

use strict;
use warnings;
use Data::Dumper;
use LWP::UserAgent;
use JSON::Create 'create_json';
use JSON::Parse 'parse_json';
use Config::Simple;

use Nabovarme::Db;
use Nabovarme::Utils;

use constant CONFIG_FILE => '/etc/Nabovarme.conf';

# Load configuration
my $api_key = $ENV{'GOOGLE_API_KEY'} 
	or log_die("ERROR: GOOGLE_API_KEY environment variable not set");

my $url     = $ENV{'GOOGLE_GEOLOCATION_API_URL'} 
	or log_die("ERROR: GOOGLE_GEOLOCATION_API_URL environment variable not set");

# Database connection
log_info("Connecting to the database...");
my $dbh = Nabovarme::Db->my_connect;
$dbh->{'mysql_auto_reconnect'} = 1;

# Main processing
log_info("Processing meters...");
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
			log_info("Processing meter: $meter->{serial}");

			my $wifi_data = fetch_wifi_data($dbh, $meter->{serial});
			
			if ($wifi_data) {
				log_info("Fetched WiFi data for meter $meter->{serial}");
				my $location = get_location($wifi_data);
				
				if ($location) {
					log_info("Location found for meter $meter->{serial}: $location->{lat}, $location->{lng}");
					update_meter_location($dbh, $meter->{serial}, $location);
				} else {
					log_warn("No location found for meter $meter->{serial}");
				}
			} else {
				log_warn("No WiFi data found for meter $meter->{serial}");
			}
		}
	}
}

sub fetch_wifi_data {
	my ($dbh, $serial) = @_;
	my $quoted_serial = $dbh->quote($serial);
	
	log_info("Fetching WiFi data for meter $serial");
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
				signalStrength  => int($wifi->{rssi}),
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
	
	log_info("Requesting geolocation...");
	my $request_data = {
		considerIp		=> 'false',
		wifiAccessPoints  => $wifi_data
	};
	
	my $json_request = create_json($request_data);
	my $response = send_geolocation_request($json_request);
	
	return parse_location_response($response) if $response;
	log_warn("Failed to get location data from geolocation service");
	return;
}

sub send_geolocation_request {
	my ($json_request) = @_;
	
	log_info("Sending geolocation request...");
	my $req = HTTP::Request->new(POST => $url . $api_key);

	$req->header('Content-Type'   => 'application/json');
	$req->header('Content-Length' => length($json_request));
	$req->content($json_request);

	my $ua = LWP::UserAgent->new;
	my $response = $ua->request($req);
	
	if ($response->is_success) {
		log_info("Geolocation request successful");
		return $response;
	} else {
		log_info("ERROR: Geolocation request failed: " . $response->status_line);
		log_info("ERROR BODY: " . $response->decoded_content);
		return undef;
	}
}

sub parse_location_response {
	my ($response) = @_;
	
	log_info("Parsing location response...");
	my $location_data = parse_json($response->decoded_content);
	
	if ($location_data->{location}) {
		return $location_data->{location};
	} else {
		log_warn("Location data missing in response");
		return undef;
	}
}

sub update_meter_location {
	my ($dbh, $serial, $location) = @_;
	
	log_info("Updating location for meter $serial in database...");
	my $lat = $dbh->quote($location->{lat});
	my $lng = $dbh->quote($location->{lng});
	my $quoted_serial = $dbh->quote($serial);
	
	my $update_query = qq[
		UPDATE meters 
		SET `location_lat` = $lat, `location_long` = $lng 
		WHERE `serial` = $quoted_serial
	];
	
	if ($dbh->do($update_query)) {
		log_info("Successfully updated location for meter $serial");
	} else {
		log_warn("Failed to update location for meter $serial: $!");
	}
}

__END__
