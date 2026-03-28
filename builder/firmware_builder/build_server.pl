#!/usr/bin/perl -w

use strict;
use warnings;

use HTTP::Daemon;
use HTTP::Status qw(:constants);
use HTTP::Response;
use JSON;
use Redis;

use lib qw( /usr/local/share/perl );
use Nabovarme::Db;

use constant DOCKER_IMAGE => 'firmware_sdk:latest';
use constant RELEASE_DIR => '/meterlogger/MeterLogger/release';

my $REDIS_QUEUE = "firmware_build_queue";

# Redis connection
my $redis_host = $ENV{'REDIS_HOST'}
	or die "ERROR: REDIS_HOST environment variable not set";

my $redis_port = $ENV{'REDIS_PORT'}
	or die "ERROR: REDIS_PORT environment variable not set";

my $redis = Redis->new(
	server => "$redis_host:$redis_port",
);

# Start 10 workers (forks)
for (1..10) {

	my $pid = fork();

	if ($pid == 0) {

		print "Worker $_ started (pid $$)\n";

		while (1) {

			my $job_json = $redis->blpop($REDIS_QUEUE, 0);
			my ($queue, $data) = @$job_json;

			my $job = decode_json($data);

			print "Worker $$ building serial: $job->{serial}\n";

			run_docker_build(
				$job->{serial},
				$job->{key},
				$job->{sw_version}
			);
		}

		exit;
	}
}

# HTTP server
my $daemon = HTTP::Daemon->new(
	LocalPort => 5000,
	Reuse => 1,
) or die "Cannot start server: $!";

print "Server running at: ", $daemon->url, "\n";

while (my $conn = $daemon->accept) {

	while (my $req = $conn->get_request) {

		if ($req->method eq 'POST' && $req->url->path eq '/rpc') {

			my $data;

			eval {
				$data = decode_json($req->content);
			};

			if ($@ || !$data->{method}) {

				$conn->send_response(HTTP::Response->new(
					400,
					'Bad Request',
					['Content-Type' => 'application/json'],
					encode_json({ error => "Invalid JSON-RPC request" })
				));

				next;
			}

			my $method = $data->{method};
			my $params = $data->{params} || {};
			my $id = $data->{id};

			my $result;

			eval {

				if ($method eq 'build') {

					my $serial = $params->{serial}
						or die "Missing serial";

					my $dbh = Nabovarme::Db->my_connect
						or die "DB connection failed";

					my $sth = $dbh->prepare(
						"SELECT `key`, sw_version FROM meters WHERE serial = " . $dbh->quote($serial) . " LIMIT 1"
					);

					$sth->execute;

					if (my $row = $sth->fetchrow_hashref) {

						enqueue_job($serial, $row->{key}, $row->{sw_version});

						$result = { success => 1, queued => 1 };
					}
					else {
						die "Meter not found";
					}
				}
				elsif ($method eq 'build_all') {

					my $dbh = Nabovarme::Db->my_connect
						or die "DB connection failed";

					my $sth = $dbh->prepare("
						SELECT serial, `key`, sw_version
						FROM meters
						WHERE enabled = 1
					");

					$sth->execute;

					my $count = 0;

					while (my $row = $sth->fetchrow_hashref) {

						enqueue_job(
							$row->{serial},
							$row->{key},
							$row->{sw_version}
						);

						$count++;
					}

					$result = {
						success => 1,
						queued => $count
					};
				}
				else {
					die "Unknown method";
				}
			};

			my $body;

			if ($@) {

				$body = encode_json({
					jsonrpc => "2.0",
					error => "$@",
					id => $id
				});
			}
			else {

				$body = encode_json({
					jsonrpc => "2.0",
					result => $result,
					id => $id
				});
			}

			$conn->send_response(HTTP::Response->new(
				200,
				'OK',
				['Content-Type' => 'application/json'],
				$body
			));
		}
		else {
			$conn->send_response(HTTP::Response->new(404));
		}
	}

	$conn->close;
	undef($conn);
}

sub enqueue_job {
	my ($serial, $key, $sw_version) = @_;

	my $job = encode_json({
		serial => $serial,
		key => $key,
		sw_version => $sw_version
	});

	$redis->rpush($REDIS_QUEUE, $job);
}

sub run_docker_build {
	my ($serial, $key, $sw_version) = @_;

	my @build_flags = ('AP=1');

	if ($sw_version =~ /NO_AUTO_CLOSE/) {
		push @build_flags, 'AUTO_CLOSE=0';
	}

	if ($sw_version =~ /NO_CRON/) {
		push @build_flags, 'NO_CRON=1';
	}

	if ($sw_version =~ /DEBUG_STACK_TRACE/) {
		push @build_flags, 'DEBUG_STACK_TRACE=1';
	}

	if ($sw_version =~ /THERMO_ON_AC_2/) {
		push @build_flags, 'THERMO_ON_AC_2=1';
	}

	my $extra_flags = join(' ', @build_flags);

	my $docker_cmd = join(" ",
		"docker run --rm",
		"-e SERIAL=$serial",
		"-e KEY=$key",
		"-e BUILD_FLAGS=\"$extra_flags\"",
		"-v firmware_release:" . RELEASE_DIR,
		DOCKER_IMAGE
	);

	print "Running: $docker_cmd\n";

	my $output = `$docker_cmd 2>&1`;
	my $exit_code = $? >> 8;

	my $success = ($exit_code == 0);

	if (!$success) {
		warn "Build failed for $serial\n$output\n";
	}

	return {
		serial => $serial,
		success => $success ? 1 : 0,
		exit_code => $exit_code,
		output => $output
	};
}