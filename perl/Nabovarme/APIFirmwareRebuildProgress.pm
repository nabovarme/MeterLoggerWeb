package Nabovarme::APIFirmwareRebuildProgress;

use strict;
use warnings;
use utf8;
use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::Const -compile => qw(OK);
use JSON ();
use Redis ();

sub handler {
	my $r = shift;

	$r->content_type("application/json; charset=utf-8");
	$r->headers_out->set('Cache-Control' => 'no-store, no-cache, must-revalidate, max-age=0');
	$r->err_headers_out->add("Access-Control-Allow-Origin" => '*');

	my %params;
	my $args_string = $r->args || '';
	foreach my $pair (split(/[&;]/, $args_string)) {
		my ($key, $val) = split(/=/, $pair, 2);
		next unless defined $key;
		$params{$key} = $val // '';
	}

	my $batch_id = $params{batch_id};
	if (!$batch_id) {
		$r->print(JSON->new->utf8->encode({ success => 0, error => "Missing batch_id" }));
		return Apache2::Const::OK;
	}

	my $redis;
	eval { $redis = Redis->new(server => "$ENV{REDIS_HOST}:$ENV{REDIS_PORT}"); };
	if ($@) {
		$r->print(JSON->new->utf8->encode({ success => 0, error => "Redis connection failure" }));
		return Apache2::Const::OK;
	}

	# Check if the compilation batch is still processing in the Redis active queue list
	my $is_active = 0;
	my @active_batches = $redis->lrange("firmware_active_batches", 0, -1);
	if (grep { $_ eq $batch_id } @active_batches) {
		$is_active = 1;
	}

	$r->print(JSON->new->utf8->encode({
		success   => 1,
		is_active => $is_active
	}));

	return Apache2::Const::OK;
}

1;
