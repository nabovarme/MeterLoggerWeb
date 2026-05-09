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
# SAFE EVAL WITH TIMEOUT
# --------------------------
sub safe_eval {
	my ($code, $timeout) = @_;

	my $json = JSON->new->allow_nonref;

	my $pid = fork();

	if (!defined $pid) {
		return (undef, "fork failed");
	}

	# --------------------------
	# CHILD PROCESS
	# --------------------------
	if ($pid == 0) {

		eval {
			local $SIG{__WARN__} = sub { };
			no strict 'vars';
			no warnings 'uninitialized';

			my $result = eval $code;
			my $error  = $@;

			my $payload = {
				result => defined $result ? $result : 0,
				error  => $error || '',
				warning => ''
			};

			print $json->encode($payload);
		};

		if ($@) {
			my $payload = {
				result  => 0,
				error   => $@,
				warning => ''
			};

			print $json->encode($payload);
		}

		exit 0;
	}

	# --------------------------
	# PARENT PROCESS (WATCHDOG)
	# --------------------------
	my $deadline = time() + $timeout;

	while (1) {

		my $kid = waitpid($pid, WNOHANG);

		# child finished
		if ($kid == $pid) {
			last;
		}

		# timeout → kill child
		if (time() > $deadline) {
			log_debug("timeout → killing pid=$pid\n");

			kill 'KILL', $pid;
			waitpid($pid, 0);

			return (undef, "timeout");
		}

		usleep(50_000);
	}

	return (1, undef);
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
	my $result_key = $req->{result_key};

	log_debug("eval id=$id condition=$condition\n");

	# --------------------------
	# EXECUTE WITH HARD TIMEOUT
	# --------------------------
	my ($ok, $err) = safe_eval($condition, 2);

	my $payload;

	if ($err) {
		$payload = {
			id     => $id,
			result => 0,
			error  => $err
		};
	} else {
		# NOTE: result is already printed by child,
		# but we still need a fallback structure
		$payload = {
			id     => $id,
			result => 1,
			error  => ''
		};
	}

	my $encoded = encode_json($payload);

	my $wait_key = "sandbox:wait:$id";

	$redis->rpush($wait_key, $encoded);
	$redis->expire($wait_key, 30);

	log_debug("published result id=$id\n");

	if ($processed % 100 == 0) {
		log_debug("heartbeat processed=$processed\n");
	}
}
