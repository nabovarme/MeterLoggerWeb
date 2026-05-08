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
#	use Data::Dumper; print Dumper $raw;

	$processed++;

	my $req = eval { decode_json($raw->[1]) };

	if ($@ || !$req) {
		print "warning: invalid json request\n";
		next;
	}

	my $id   = $req->{id};
	my $expr = $req->{expr};
	my $vars = $req->{vars};

	print "info: request id=$id expr=$expr\n";

	# --------------------------------------------------
	# Inject ONLY known variables from meter_alarm.pl
	# Unknown variables remain as main:: symbols
	# --------------------------------------------------
	our $flow   = $vars->{flow}   if exists $vars->{flow};
	our $closed = $vars->{closed} if exists $vars->{closed};
	our $leak   = $vars->{leak}   if exists $vars->{leak};

	my $result_key = $vars->{result_key};

	my $result = 0;

	{
		local $@;
		local $SIG{__WARN__} = sub {
			print "warning: eval warn: @_";
		};

		no strict 'vars';
		no warnings 'uninitialized';

		$result = eval $expr;
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
