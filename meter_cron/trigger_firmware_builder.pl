#!/usr/bin/perl -w

use strict;
use warnings;

use JSON;
use Redis;
use IO::Handle;

STDOUT->autoflush(1);
STDERR->autoflush(1);

# Redis connection
my $redis_host = $ENV{'REDIS_HOST'}
	or die "ERROR: REDIS_HOST environment variable not set";

my $redis_port = $ENV{'REDIS_PORT'}
	or die "ERROR: REDIS_PORT environment variable not set";

my $redis = Redis->new(
	server => "$redis_host:$redis_port",
);

# Redis keys
my $REDIS_TRIGGER = "firmware_build_trigger";

print "Sending manual rebuild trigger...\n";

# Create trigger event payload
my $payload = encode_json({
	reason => "Forced manual rebuild",
	time   => time()
});

# Push the trigger event onto the queue
$redis->lpush($REDIS_TRIGGER, $payload);

print "Trigger sent\n";

$redis->quit;
exit 0;
