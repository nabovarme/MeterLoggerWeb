package Nabovarme::APIWiFiScanRequest;

use strict;
use warnings;
use utf8;

use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::Const -compile => qw(OK HTTP_BAD_REQUEST HTTP_UNAUTHORIZED HTTP_SERVICE_UNAVAILABLE HTTP_REQUEST_TIME_OUT HTTP_INTERNAL_SERVER_ERROR);
use JSON ();

use Nabovarme::Db;
use Nabovarme::Admin;
use Nabovarme::MQTT_RPC;

sub handler {
	my $r = shift;

	# Authenticate user session
	my $admin = Nabovarme::Admin->new();
	unless ($admin->cookie_is_signed_in($r)) {
		$r->content_type("application/json; charset=utf-8");
		$r->status(Apache2::Const::HTTP_UNAUTHORIZED);
		$r->print(JSON->new->utf8->encode({ error => 'Unauthorized' }));
		return Apache2::Const::OK;
	}

	# Extract serial from URI (e.g. /api/wifi_scan_request/78590618)
	my $orig_uri = $r->unparsed_uri || $r->uri;
	my ($serial) = $orig_uri =~ m{/([A-Za-z0-9_-]{1,16})$};
	return Apache2::Const::HTTP_BAD_REQUEST unless $serial;

	$r->content_type("application/json; charset=utf-8");
	$r->err_headers_out->add("Access-Control-Allow-Origin" => '*');

	my $scan_success = 0;
	my $timeout_occurred = 0;

	# Try MQTT RPC call with callback and 10-second timeout
	eval {
		my $mqtt = Nabovarme::MQTT_RPC->new();
		if ($mqtt && $mqtt->connect()) {
			my $res = $mqtt->call({
				serial   => $serial,
				function => 'scan',
				param    => '1',
				timeout  => 10, # 10 second timeout for the meter to report back
				callback => sub {
					my $reply = shift;
					# Executed when command_queue state becomes 'received' or 'timeout'
				}
			});

			if ($res) {
				$scan_success = 1;
			} else {
				$timeout_occurred = 1;
			}
		}
	};

	if ($scan_success) {
		$r->print(JSON->new->utf8->encode({ status => 'ok', message => 'Scan completed' }));
		return Apache2::Const::OK;
	}

	if ($timeout_occurred) {
		$r->status(Apache2::Const::HTTP_REQUEST_TIME_OUT);
		$r->print(JSON->new->utf8->encode({ error => 'Meter timed out during scan' }));
		return Apache2::Const::OK;
	}

	# Fallback: If MQTT connection failed entirely, queue command without waiting
	my $dbh = Nabovarme::Db->my_connect
		or return Apache2::Const::HTTP_SERVICE_UNAVAILABLE;

	my $sth = $dbh->prepare(q{
		INSERT INTO command_queue (serial, function, param, unix_time)
		VALUES (?, 'scan', '1', UNIX_TIMESTAMP())
	});

	if ($sth->execute($serial)) {
		$r->print(JSON->new->utf8->encode({ status => 'ok', message => 'Scan command queued' }));
		return Apache2::Const::OK;
	} else {
		$r->status(Apache2::Const::HTTP_INTERNAL_SERVER_ERROR);
		$r->print(JSON->new->utf8->encode({ error => 'Failed to queue command' }));
		return Apache2::Const::OK;
	}
}

1;
