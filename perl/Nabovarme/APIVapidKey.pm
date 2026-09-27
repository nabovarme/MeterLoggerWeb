package Nabovarme::APIVapidKey;

use strict;
use warnings;
use utf8;
use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::Const -compile => qw(OK HTTP_SERVICE_UNAVAILABLE);
use JSON ();

sub handler {
	my $r = shift;

	# Only allow GET requests
	if ($r->method ne 'GET') {
		$r->content_type("application/json; charset=utf-8");
		$r->print(JSON->new->utf8->encode({ success => 0, error => "Method not allowed" }));
		return Apache2::Const::OK;
	}

	my $public_key = $ENV{VAPID_PUBLIC_KEY} || '';

	if (!$public_key) {
		$r->content_type("application/json; charset=utf-8");
		$r->print(JSON->new->utf8->encode({ success => 0, error => "VAPID public key not configured on server" }));
		return Apache2::Const::OK;
	}

	$r->content_type("application/json; charset=utf-8");
	$r->headers_out->set('Cache-Control' => 'no-store, no-cache, must-revalidate, max-age=0');
	$r->print(JSON->new->utf8->encode({
		success    => 1,
		public_key => $public_key
	}));

	return Apache2::Const::OK;
}

1;
