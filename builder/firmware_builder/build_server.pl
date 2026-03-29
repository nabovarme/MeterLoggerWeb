#!/usr/bin/perl -w

use strict;
use warnings;

use JSON;
use Redis;

use File::Path qw(make_path);
use File::Copy qw(move);

use lib qw( /usr/local/share/perl );
use Nabovarme::Db;

use constant DOCKER_IMAGE => 'firmware_sdk:latest';
use constant RELEASE_DIR => '/meterlogger/MeterLogger/release';
use constant BUILDERS => 10;

my $REDIS_QUEUE = "firmware_build_queue";
my $REDIS_TRIGGER = "firmware_build_trigger";

# Redis connection
my $redis_host = $ENV{'REDIS_HOST'}
	or die "ERROR: REDIS_HOST environment variable not set";

my $redis_port = $ENV{'REDIS_PORT'}
	or die "ERROR: REDIS_PORT environment variable not set";

my $redis = Redis->new(
	server => "$redis_host:$redis_port",
);

# Start 10 workers (forks)
for (1..BUILDERS) {

	my $pid = fork();

	if ($pid == 0) {

		print "Worker $_ started (pid $$)\n";

		while (1) {

			my $job_json = $redis->blpop($REDIS_QUEUE, 0);
			my ($queue, $data) = @$job_json;

			my $job = decode_json($data);

			print "Worker $$ building serial: $job->{serial}\n";

			run_docker_build(
				$job->{serial}
			);
		}

		exit;
	}
}

print "Workers started\n";

# Trigger listener (DB + enqueue jobs happens here)
while (1) {

	my $data = $redis->blpop($REDIS_TRIGGER, 0);
	my (undef, $payload) = @$data;

	my $trigger = decode_json($payload);

	print "Processing build trigger\n";

	process_build($trigger);
}

sub process_build {
	my ($trigger) = @_;

	my $dbh = Nabovarme::Db->my_connect
		or die "DB connection failed";

	my $sth = $dbh->prepare("
		SELECT serial
		FROM meters
		WHERE enabled = 1
		ORDER BY serial
	");

	$sth->execute;

	while (my $row = $sth->fetchrow_hashref) {

		# Dedup
		my $dedup_key = "build-job:$row->{serial}";

		# Skip if already enqueued recently
		next unless $redis->set($dedup_key, 1, 'NX', 'EX', 3600);

		my $job = encode_json({
			serial => $row->{serial},
			trigger_time => time()
		});

		$redis->rpush($REDIS_QUEUE, $job);
	}

	print "Jobs enqueued (deduplicated)\n";
}

sub run_docker_build {
	my ($serial) = @_;

	my $dbh = Nabovarme::Db->my_connect
		or die "DB connection failed";

	my $sth = $dbh->prepare("
		SELECT `key`, sw_version
		FROM meters
		WHERE serial = ?
	");

	$sth->execute($serial);

	my $row = $sth->fetchrow_hashref
		or die "No meter found for serial $serial";

	my $key = $row->{key};
	my $sw_version = $row->{sw_version} // 'unknown';

	# filesystem safe version (ONLY for paths)
	my $fs_version = $sw_version;
	$fs_version =~ s/[^a-zA-Z0-9._-]//g;
	$fs_version = 'unknown' if !$fs_version;

	my $firmware_path = RELEASE_DIR . "/$serial/$fs_version/firmware.bin";

	# Skip if already built
	if (-f $firmware_path) {
		print "Skipping build for $serial (already exists)\n";
		return {
			serial => $serial,
			skipped => 1,
			reason => 'already_built'
		};
	}

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

	if ($success) {

		prepare_release_structure($serial, $fs_version);
		generate_manifest($serial, $sw_version, $fs_version);
		generate_firmware_index();
	}

	return {
		serial => $serial,
		success => $success ? 1 : 0,
		exit_code => $exit_code,
		output => $output
	};
}

sub prepare_release_structure {
	my ($serial, $fs_version) = @_;

	my $base_dir = RELEASE_DIR;
	my $serial_dir = "$base_dir/$serial";
	my $version_dir = "$serial_dir/$fs_version";

	my $src = "$base_dir/$serial.bin";
	my $dst = "$version_dir/firmware.bin";

	make_path($version_dir);

	unlink $dst if -f $dst;

	if (-f $src) {
		move($src, $dst)
			or die "Cannot move $src to $dst: $!";
	}
	else {
		die "Firmware file not found: $src";
	}

	my $latest_link = "$serial_dir/latest";

	unlink $latest_link if -l $latest_link || -e $latest_link;

	symlink($fs_version, $latest_link)
		or warn "Could not create symlink: $!";
}

sub generate_manifest {
	my ($serial, $sw_version, $fs_version) = @_;

	my $dir = RELEASE_DIR . "/$serial/$fs_version";

	my $manifest = {
		name => "MeterLogger $serial",
		version => $sw_version || 'unknown',
		builds => [
			{
				chipFamily => "ESP8266",
				parts => [
					{
						path => "firmware.bin",
						offset => 0
					}
				]
			}
		]
	};

	open(my $fh, ">", "$dir/manifest.json")
		or die "Cannot write manifest: $!";

	print $fh encode_json($manifest);
	close($fh);
}

sub generate_firmware_index {

	opendir(my $dh, RELEASE_DIR) or die "Cannot open dir";

	my @firmwares;

	while (my $serial = readdir($dh)) {

		next if ($serial =~ /^\./);

		my $latest = RELEASE_DIR . "/$serial/latest";

		next unless -l $latest;

		my $target = readlink($latest);
		my $manifest_path = "$serial/$target/manifest.json";

		if (-f RELEASE_DIR . "/$manifest_path") {

			push @firmwares, {
				name => "$serial ($target)",
				path => $manifest_path
			};
		}
	}

	closedir($dh);

	open(my $fh, ">", RELEASE_DIR . "/firmwares.json")
		or die "Cannot write index";

	print $fh encode_json(\@firmwares);
	close($fh);
}
