package Nabovarme::APIPushSubscribe;

use strict;
use warnings;
use utf8;
use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::Const -compile => qw(OK HTTP_SERVICE_UNAVAILABLE);
use JSON ();
use Nabovarme::Db;

sub handler {
	my $r = shift;

	if ($r->method ne 'POST') {
		$r->content_type("application/json; charset=utf-8");
		$r->print(JSON->new->utf8->encode({ success => 0, error => "Method not allowed" }));
		return Apache2::Const::OK;
	}

	# 1. Read POST body reliably in mod_perl 2
	my $body_data = '';

	# Primary Method: Read directly from Apache request stream using $r->read()
	my $content_length = $r->headers_in->{'Content-Length'} || 0;
	if ($content_length > 0) {
		$r->read($body_data, $content_length);
	}

	# Fallback Method: If $r->read() returned 0 bytes because an access handler
	# already consumed the filter stream, check $r->pnotes or $r->args
	if (!$body_data && $r->pnotes('POST_DATA')) {
		$body_data = $r->pnotes('POST_DATA');
	}

	my $payload = eval { JSON::decode_json($body_data) } || {};
	my $serial   = $payload->{serial}   || '';
	my $endpoint = $payload->{endpoint} || '';
	my $p256dh   = $payload->{p256dh}   || '';
	my $auth     = $payload->{auth}     || '';

	# Direct Parameter Fallback: In case the POST payload was parsed as form-urlencoded
	if (!$serial || !$endpoint || !$p256dh || !$auth) {
		if ($r->can('param')) {
			$serial   ||= $r->param('serial')   || '';
			$endpoint ||= $r->param('endpoint') || '';
			$p256dh   ||= $r->param('p256dh')   || '';
			$auth     ||= $r->param('auth')     || '';
		}
	}

	if (!$serial || !$endpoint || !$p256dh || !$auth) {
		warn sprintf("[APIPushSubscribe Error] Missing parameters -> serial: '%s', endpoint: '%s', p256dh: '%s', auth: '%s'\n",
			$serial, $endpoint, $p256dh, $auth);

		$r->content_type("application/json; charset=utf-8");
		$r->print(JSON->new->utf8->encode({ 
			success => 0, 
			error => "Missing required subscription parameters" 
		}));
		return Apache2::Const::OK;
	}

	my $dbh = Nabovarme::Db->my_connect;
	if ($dbh) {
		my $sql = q[
			INSERT INTO push_subscriptions (serial, endpoint, p256dh, auth, user_agent, unix_time)
			VALUES (?, ?, ?, ?, ?, unix_timestamp())
			ON DUPLICATE KEY UPDATE
				serial = VALUES(serial),
				p256dh = VALUES(p256dh),
				auth = VALUES(auth),
				user_agent = VALUES(user_agent),
				unix_time = unix_timestamp()
		];

		my $user_agent = $r->headers_in->{'User-Agent'} || '';
		my $sth = $dbh->prepare($sql);
		$sth->execute($serial, $endpoint, $p256dh, $auth, $user_agent);

		$r->content_type("application/json; charset=utf-8");
		$r->print(JSON->new->utf8->encode({ success => 1 }));
		return Apache2::Const::OK;
	}

	$r->err_headers_out->set('Retry-After' => '60');
	return Apache2::Const::HTTP_SERVICE_UNAVAILABLE;
}

1;
