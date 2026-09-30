package Nabovarme::APIWiFiScanRequest;

use strict;
use warnings;
use utf8;

use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::Const -compile => qw(OK HTTP_BAD_REQUEST HTTP_UNAUTHORIZED HTTP_SERVICE_UNAVAILABLE HTTP_INTERNAL_SERVER_ERROR);
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

	my $sent_via_mqtt = 0;

	# Step 1: Try sending instant MQTT RPC scan command
	eval {
		my $mqtt = Nabovarme::MQTT_RPC->new();
		if ($mqtt && $mqtt->connect()) {
			$mqtt->call({
				serial   => $serial,
				function => 'scan',
				param    => '1',
				callback => undef,
				timeout  => undef
			});
			$sent_via_mqtt = 1;
		}
	};

	if ($sent_via_mqtt) {
		$r->print(JSON->new->utf8->encode({ status => 'ok', message => 'Scan command sent via MQTT' }));
		return Apache2::Const::OK;
	}

	# Step 2: Fallback to inserting command in command_queue if MQTT fails/times out
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
