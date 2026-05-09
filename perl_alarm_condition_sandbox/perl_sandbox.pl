#!/usr/bin/perl -w

use strict;
use warnings;

use JSON;
use Redis;
use IO::Handle;
use POSIX ":sys_wait_h";
use Time::HiRes qw(usleep time);

STDOUT->autoflush(1);
STDERR->autoflush(1);

# --------------------------
# CONFIG
# --------------------------
my $DEBUG = ($ENV{ENABLE_DEBUG} // 0) =~ /^(1|true|yes)$/i;

$SIG{USR1} = sub {
	$DEBUG = !$DEBUG;
	print STDERR "[DEBUG] toggled => " . ($DEBUG ? "enabled" : "disabled") . "\n";
};

sub log_debug {
	return unless $DEBUG;
	print STDERR @_;
}

# --------------------------
# REDIS
# --------------------------
my $redis_host = $ENV{REDIS_HOST} || die "REDIS_HOST missing";
my $redis_port = $ENV{REDIS_PORT} || die "REDIS_PORT missing";

log_debug("starting sandbox worker on $redis_host:$redis_port\n");

my $redis = Redis->new(server => "$redis_host:$redis_port");

log_debug("connected to redis\n");

# --------------------------
# SAFE EVAL WITH TIMEOUT + IPC
# --------------------------
sub safe_eval {
	my ($code, $timeout) = @_;

	my $json = JSON->new->allow_nonref;

	pipe(my $rh, my $wh) or return (undef, "pipe failed");

	my $pid = fork();
	if (!defined $pid) {
		return (undef, "fork failed");
	}

	# ---------------- CHILD ----------------
	if ($pid == 0) {
		close $rh;

		my $payload = {
			result  => 0,
			error   => '',
			warning => '',
		};

		eval {
			local $SIG{__WARN__} = sub {
				$payload->{warning} .= join('', @_);
			};

			no strict;
			no warnings;

			$payload->{result} = eval $code;
			$payload->{error}  = $@ if $@;
		};

		print $wh $json->encode($payload);
		close $wh;
		exit 0;
	}

	# ---------------- PARENT ----------------
	close $wh;

	my $deadline = time() + $timeout;

	while (1) {

		my $kid = waitpid($pid, WNOHANG);

		if ($kid == $pid) {
			last;
		}

		if (time() > $deadline) {
			log_debug("timeout → killing pid=$pid\n");
			kill 'KILL', $pid;
			waitpid($pid, 0);
			close $rh;
			return (undef, "timeout");
		}

		usleep(50_000);
	}

	my $response = do { local $/; <$rh> };
	close $rh;

	return (undef, "invalid child response") unless $response;

	my $data = eval { decode_json($response) };
	return (undef, "invalid child response") if $@ || !$data;

	return ($data, undef);
}

# --------------------------
# MAIN LOOP
# --------------------------
my $processed = 0;

while (1) {

	my $raw = $redis->blpop("sandbox:requests", 0);
	next unless $raw;

	$processed++;

	my $req = eval { decode_json($raw->[1]) };

	if ($@ || !$req) {
		log_debug("invalid json request\n");
		next;
	}

	my $id        = $req->{id};
	my $condition = $req->{condition};

	log_debug("eval id=$id condition=$condition\n");

	my ($payload, $err) = safe_eval($condition, 2);

	# --------------------------
	# NORMALIZE PAYLOAD
	# --------------------------
	if ($err || !$payload) {
		$payload = {
			result  => 0,
			error   => $err || "invalid child response",
			warning => ''
		};
	}

	$payload->{id} = $id;

	my $encoded = encode_json($payload);

	my $wait_key = "sandbox:wait:$id";

	$redis->rpush($wait_key, $encoded);
	$redis->expire($wait_key, 30);

	log_debug(
		"published result=$payload->{result} id=$id " . 
		($payload->{error} ? " error=$payload->{error}" : '') . 
		($payload->{warning} ? " warning=$payload->{warning}\n" : '')
	);

	if ($processed % 100 == 0) {
		log_debug("heartbeat processed=$processed\n");
	}
}
