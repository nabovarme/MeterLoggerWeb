package Nabovarme::APIPushSubscribe;

use strict;
use warnings;
use utf8;
use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::Const -compile => qw(OK HTTP_SERVICE_UNAVAILABLE);
use JSON ();
use Nabovarme::Db;
use Nabovarme::Number::Phone;

sub handler {
	my $r = shift;

	if ($r->method ne 'POST') {
		$r->content_type("application/json; charset=utf-8");
		$r->print(JSON->new->utf8->encode({ success => 0, error => "Method not allowed" }));
		return Apache2::Const::OK;
	}

	# Read POST JSON body natively from the pristine request stream
	my $body_data = '';
	my $content_length = $r->headers_in->{'Content-Length'} || 0;
	if ($content_length > 0) {
		$r->read($body_data, $content_length);
	}

	my $payload = eval { JSON::decode_json($body_data) } || {};
	my $raw_phone = $payload->{phone}    || '';
	my $endpoint  = $payload->{endpoint} || '';
	my $p256dh    = $payload->{p256dh}   || '';
	my $auth      = $payload->{auth}     || '';

	if (!$raw_phone || !$endpoint || !$p256dh || !$auth) {
		warn sprintf("[APIPushSubscribe Error] Missing parameters -> phone: '%s', endpoint: '%s', p256dh: '%s', auth: '%s'\n",
			$raw_phone, $endpoint, $p256dh, $auth);

		$r->content_type("application/json; charset=utf-8");
		$r->print(JSON->new->utf8->encode({ 
			success => 0, 
			error => "Missing required subscription parameters" 
		}));
		return Apache2::Const::OK;
	}

	# Normalize and compact the phone number for consistent database matching
	my $phone_obj = Nabovarme::Number::Phone->new($raw_phone);
	my $phone = ($phone_obj && $phone_obj->is_valid) ? $phone_obj->compact : $raw_phone;

	my $dbh = Nabovarme::Db->my_connect;
	if ($dbh) {
		my $sql = q[
			INSERT INTO push_subscriptions (phone, endpoint, p256dh, auth, user_agent, unix_time)
			VALUES (?, ?, ?, ?, ?, unix_timestamp())
			ON DUPLICATE KEY UPDATE
				phone = VALUES(phone),
				p256dh = VALUES(p256dh),
				auth = VALUES(auth),
				user_agent = VALUES(user_agent),
				unix_time = unix_timestamp()
		];

		my $user_agent = $r->headers_in->{'User-Agent'} || '';
		my $sth = $dbh->prepare($sql);
		$sth->execute($phone, $endpoint, $p256dh, $auth, $user_agent);

		$r->content_type("application/json; charset=utf-8");
		$r->print(JSON->new->utf8->encode({ success => 1 }));
		return Apache2::Const::OK;
	}

	$r->err_headers_out->set('Retry-After' => '60');
	return Apache2::Const::HTTP_SERVICE_UNAVAILABLE;
}

1;
