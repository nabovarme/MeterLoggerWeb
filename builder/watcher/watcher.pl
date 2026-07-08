#!/usr/bin/perl -w

use strict;
use warnings;

use JSON;
use LWP::UserAgent;
use Redis;

use IO::Handle;

STDOUT->autoflush(1);
STDERR->autoflush(1);

my $REPO_URL = $ENV{'WATCHER_REPO_URL'}
	or die "ERROR: WATCHER_REPO_URL environment variable not set";

my $CHECK_INTERVAL = 300;

# Redis connection configurations
my $redis_host = $ENV{'REDIS_HOST'}
	or die "ERROR: REDIS_HOST environment variable not set";

my $redis_port = $ENV{'REDIS_PORT'}
	or die "ERROR: REDIS_PORT environment variable not set";

# Auto-reconnection prevents drops over extended sleep loops
my $redis = Redis->new(
	server    => "$redis_host:$redis_port",
	reconnect => 5,    # Retry 5 times on drop
	every     => 1000, # Wait 1000ms between attempts
);

# Redis keys
my $REDIS_TRIGGER = "firmware_build_trigger";

my $last_sha = "";
my $current_sha = "";

my $running = 1;

$SIG{TERM} = sub {
	print "Received TERM - shutting down cleanly\n";
	$running = 0;
};

$SIG{INT} = sub {
	print "Received INT - shutting down cleanly\n";
	$running = 0;
};

$SIG{HUP} = sub {
	print "Received HUP signal - triggering build\n";
	trigger_build("manual");
};

while ($running) {

	my $ua = LWP::UserAgent->new;
	$ua->timeout(10);

	my $res = $ua->get($REPO_URL);

	if ($res->is_success) {

		my $json = decode_json($res->decoded_content);
		my $sha = $json->{sha};

		$current_sha = $sha;

		if (!$last_sha || $sha ne $last_sha) {

			print "Repo updated\n";

			$last_sha = $sha;

			trigger_build("git_update");
		}
		else {
			print "No changes\n";
		}
	}
	else {
		warn "GitHub check failed: " . $res->status_line;
	}

	# Explicit check to stop sleeping instantly if a termination signal was caught
	last unless $running;
	sleep($CHECK_INTERVAL);
}

sub trigger_build {
	my ($reason) = @_;

	print "Triggering build ($reason)\n";

	# Wrap push action in an evaluation block to recover connection dynamically if stale
	eval {
		$redis->ping; # Validates connection life trace before issuing pipeline mutations
		$redis->rpush($REDIS_TRIGGER, encode_json({
			reason => $reason,
			time => time()
		}));
	};
	if ($@) {
		warn "Redis push exception intercepted, attempting fallback drop reconnect sequence: $@\n";
		eval {
			$redis = Redis->new(
				server    => "$redis_host:$redis_port",
				reconnect => 5,
				every     => 1000,
			);
			$redis->rpush($REDIS_TRIGGER, encode_json({
				reason => $reason,
				time => time()
			}));
		};
		if ($@) {
			die "Fatal: Absolute connection loss to Redis task pipeline broker network: $@";
		}
	}

	print "Trigger sent\n";
}

1;
