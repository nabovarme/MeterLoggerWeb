#!/usr/bin/perl -w

use strict;
use warnings;

use JSON;
use LWP::UserAgent;

my $REPO_URL = "https://api.github.com/repos/nabovarme/MeterLogger/commits/master";
my $CHECK_INTERVAL = 30; # seconds

# URL til din builder container (Docker service navn)
my $BUILDER_URL = "http://firmware-builder:5000/build-all";

my $last_sha = "";

while (1) {

	my $ua = LWP::UserAgent->new;
	$ua->timeout(10);

	my $res = $ua->get($REPO_URL);

	if ($res->is_success) {
		my $json = decode_json($res->decoded_content);
		my $sha = $json->{sha};

		if (!$last_sha || $sha ne $last_sha) {
			print "Repo updated: $sha\n";

			$last_sha = $sha;

			trigger_build($sha);
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
	my ($sha) = @_;

	print "Triggering build for $sha\n";

	my $ua = LWP::UserAgent->new;
	$ua->timeout(300);

	my $res = $ua->post(
		$BUILDER_URL,
		'Content-Type' => 'application/json',
		Content => encode_json({})
	);

	if ($res->is_success) {
		print "Build triggered successfully\n";
		print $res->decoded_content . "\n";
	}
	else {
		warn "Failed to trigger build: " . $res->status_line;
	}
}
