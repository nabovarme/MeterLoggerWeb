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
	my $scan_timeout_sec = 8; # 8 seconds (less than OpenResty's proxy timeout)

	# Execute MQTT call guarded by a hard SIGALRM timer
	eval {
		local $SIG{ALRM} = sub { die "TIMEOUT\n" };
		alarm($scan_timeout_sec);

		my $mqtt = Nabovarme::MQTT_RPC->new();
		if ($mqtt && $mqtt->connect()) {
			my $res = $mqtt->call({
				serial   => $serial,
				function => 'scan',
				param    => '1',
				stateful => 0,
				timeout  => 0,
				callback => sub {
					my $reply = shift;
				}
			});

			if ($res) {
				$scan_success = 1;
			} else {
				$timeout_occurred = 1;
			}
		}

		alarm(0); # Cancel alarm if completed in time
	};
	alarm(0); # Ensure alarm is reset in case of errors

	if ($@) {
		if ($@ eq "TIMEOUT\n") {
			$timeout_occurred = 1;
		} else {
			warn "Error during scan request for serial $serial: $@";
		}
	}

	if ($scan_success) {
		$r->print(JSON->new->utf8->encode({ status => 'ok', message => 'Scan completed' }));
		return Apache2::Const::OK;
	}

	if ($timeout_occurred) {
		# Return structured JSON with HTTP 408 before gateway proxy times out
		$r->status(Apache2::Const::HTTP_REQUEST_TIME_OUT);
		$r->print(JSON->new->utf8->encode({ error => 'Timeout waiting for meter response' }));
		return Apache2::Const::OK;
	}

	# Fallback: Queue scan command if MQTT failed entirely
	my $dbh = Nabovarme::Db->my_connect
		or return Apache2::Const::HTTP_SERVICE_UNAVAILABLE;

	my $sth = $dbh->prepare(q{
		INSERT INTO command_queue (serial, function, param, unix_time, is_stateful)
		VALUES (?, 'scan', '1', UNIX_TIMESTAMP(), 0)
	});

	if ($sth->execute($serial)) {
		$r->print(JSON->new->utf8->encode({ status => 'ok', message => 'Scan command queued' }));
		return Apache2::Const::OK;
	} else {
		$r->status(Apache2::Const::HTTP_INTERNAL_SERVER_ERROR);
		$r->print(JSON->new->utf8->encode({ error => 'Queue failed' }));
		return Apache2::Const::OK;
	}
}

1;
