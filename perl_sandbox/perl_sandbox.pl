#!/usr/bin/perl -w

use strict;
use warnings;

use JSON;
use Redis;

$| = 1;

my $redis_host = $ENV{REDIS_HOST} || die "REDIS_HOST missing";
my $redis_port = $ENV{REDIS_PORT} || die "REDIS_PORT missing";

print "starting sandbox worker on $redis_host:$redis_port\n";

my $redis = Redis->new(
	server => "$redis_host:$redis_port"
);

print "connected to redis\n";

my $processed = 0;

while (1) {

	my $raw = $redis->blpop("sandbox:requests", 0);
	next unless $raw;

	$processed++;

	my $req = eval { decode_json($raw->[1]) };

	if ($@ || !$req) {
		print "warning: invalid json request\n";
		next;
	}

	my $id   = $req->{id};
	my $condition = $req->{condition};
	my $result_key = $req->{result_key};

	print "info: request id=$id condition=$condition\n";

	my $result = 0;

	{
		local $@;
		local $SIG{__WARN__} = sub {
			print "warning: eval warn: @_";
		};

		no strict 'vars';
		no warnings 'uninitialized';

		$result = eval $condition;
	}

	if ($@) {
		print "error: eval failed id=$id $@\n";

		$redis->set($result_key, encode_json({
			id    => $id,
			error => "$@"
		}));

		$redis->expire($result_key, 30);

		next;
	}

	print "info: result id=$id => $result\n";

	$redis->set($result_key, encode_json({
		id     => $id,
		result => $result ? 1 : 0
	}));

	$redis->expire($result_key, 30);

	if ($processed % 100 == 0) {
		print "info: heartbeat processed=$processed\n";
	}
}
