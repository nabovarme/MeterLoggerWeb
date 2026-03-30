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

my $CHECK_INTERVAL = 120;

# Redis connection
my $redis_host = $ENV{'REDIS_HOST'}
	or die "ERROR: REDIS_HOST environment variable not set";

my $redis_port = $ENV{'REDIS_PORT'}
	or die "ERROR: REDIS_PORT environment variable not set";

my $redis = Redis->new(
	server => "$redis_host:$redis_port",
);

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

	sleep($CHECK_INTERVAL);
}

sub trigger_build {
	my ($reason) = @_;

	print "Triggering build ($reason)\n";

	# just emit a trigger event — no payload needed
	$redis->rpush("firmware_build_trigger", encode_json({
		reason => $reason,
		time => time()
	}));

	print "Trigger sent\n";
}
