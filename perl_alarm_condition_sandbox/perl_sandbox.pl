#!/usr/bin/perl -w

use strict;
use warnings;

use JSON;
use Redis;

use IO::Handle;

STDOUT->autoflush(1);
STDERR->autoflush(1);

my $DEBUG = ($ENV{ENABLE_DEBUG} // 0) =~ /^(1|true|yes)$/i;

$SIG{USR1} = sub {
	$DEBUG = !$DEBUG;

	my $state = $DEBUG ? "enabled" : "disabled";
	print STDERR "[DEBUG] toggled via USR1 => $state\n";
};

my $redis_host = $ENV{REDIS_HOST} || die "REDIS_HOST missing";
my $redis_port = $ENV{REDIS_PORT} || die "REDIS_PORT missing";

log_debug("starting sandbox worker on $redis_host:$redis_port\n");

my $redis = Redis->new(
	server => "$redis_host:$redis_port"
);

log_debug("connected to redis\n");

my $processed = 0;

while (1) {

	# --------------------------------------------------
	# BLOCKING JOB FETCH
	# --------------------------------------------------
	my $raw = $redis->blpop("sandbox:requests", 0);
	next unless $raw;

	$processed++;

	my $req = eval { decode_json($raw->[1]) };

	if ($@ || !$req) {
		log_debug("warning: invalid json request\n");
		next;
	}

	my $id         = $req->{id};
	my $condition   = $req->{condition};
	my $result_key  = $req->{result_key};

	log_debug("info: request id=$id condition=$condition\n");

	my $result;
	my $error   = '';
	my $warning = '';

	{
		local $@;

		local $SIG{__WARN__} = sub {
			my $msg = join('', @_);
			$warning .= $msg;
			log_debug("warning: eval warn: $msg");
		};

		no strict 'vars';
		no warnings 'uninitialized';

		$result = eval $condition;

		$error = $@ if $@;
	}

	# --------------------------------------------------
	# BUILD RESPONSE
	# --------------------------------------------------
	my $payload = {
		id      => $id,
		result  => defined $result ? $result : 0,
		warning => $warning // '',
	};

	if ($error) {
		log_debug("error: eval failed id=$id $error\n");

		$payload->{error} = "$error";
	}

	my $encoded = encode_json($payload);

	# --------------------------------------------------
	# EVENT NOTIFICATION
	# --------------------------------------------------
	# This unblocks the main daemon BLPOP:
	# sandbox:wait:<eval_id>

	my $wait_key = "sandbox:wait:$id";

	$redis->rpush($wait_key, $encoded);
	$redis->expire($wait_key, 30);

	log_debug("info: result published id=$id => $payload->{result}\n");

	if ($processed % 100 == 0) {
		log_debug("info: heartbeat processed=$processed\n");
	}
}

sub log_debug {
	return unless $DEBUG;
	print @_;
}
