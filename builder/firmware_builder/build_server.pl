#!/usr/bin/perl -w

use strict;
use warnings;

use JSON;
use Redis;

use File::Path qw(make_path);
use File::Copy qw(move);
use IO::Handle;

use lib qw( /usr/local/share/perl );
use Nabovarme::Db;

use constant DOCKER_IMAGE => 'firmware_sdk:latest';
use constant RELEASE_DIR => '/meterlogger/MeterLogger/release';

my $REDIS_QUEUE = "firmware_build_queue";
my $REDIS_TRIGGER = "firmware_build_trigger";

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

# Start workers (forks)
my $cpu_cores = `nproc`;
chomp $cpu_cores;
my $workers = $cpu_cores * 2;

for (1..$workers) {
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

sub get_git_version_from_docker {
	my $cmd = join(" ",
		"docker run --rm",
		DOCKER_IMAGE,
		"sh -c",
		"echo \$(git rev-parse --abbrev-ref HEAD)-\$(git rev-list HEAD --count)-\$(git describe --abbrev=4 --dirty --always)"
	);

	my $version = `$cmd`;
	chomp $version;

	return $version;
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

		my $job = encode_json({
			serial => $row->{serial},
			trigger_time => time()
		});

		$redis->rpush($REDIS_QUEUE, $job);
	}

	print "Jobs enqueued\n";
}

sub run_docker_build {
	my ($serial) = @_;

	my $lock_key = "build-lock:$serial";

	# try to acquire lock
	my $got_lock = $redis->set($lock_key, 1, 'NX', 'EX', 7200);

	if (!$got_lock) {
		print "Skipping $serial (already in progress)\n";
		return;
	}

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
	my $db_sw_version = $row->{sw_version} // 'unknown';
	my $sw_version = get_git_version_from_docker();

	# filesystem safe version (ONLY for paths)
	my $fs_version = $sw_version;
	$fs_version =~ s/[^a-zA-Z0-9._-]/_/g;
	$fs_version = 'unknown' if !$fs_version;

	my $firmware_path = RELEASE_DIR . "/$serial/$fs_version/firmware.bin";

	# Skip if already built
	if (-f $firmware_path) {
		print "Skipping build for $serial (already exists)\n";
		$redis->del($lock_key);
		return {
			serial => $serial,
			skipped => 1,
			reason => 'already_built'
		};
	}

	my $build_flags = 'AP=1';

	if ($db_sw_version =~ /NO_AUTO_CLOSE/) {
		$build_flags .= ' AUTO_CLOSE=0';
	}

	if ($db_sw_version =~ /NO_CRON/) {
		$build_flags .= ' NO_CRON=1';
	}

	if ($db_sw_version =~ /DEBUG_STACK_TRACE/) {
		$build_flags .= ' DEBUG_STACK_TRACE=1';
	}

	if ($db_sw_version =~ /THERMO_ON_AC_2/) {
		$build_flags .= ' THERMO_ON_AC_2=1';
	}

	# hardware model logic
	if ($db_sw_version =~ /MC-B/) {
		$build_flags .= ' MC_66B=1';
	}
	elsif ($db_sw_version =~ /MC/) {
		$build_flags .= ' EN61107=1';
	}
	elsif ($db_sw_version =~ /NO_METER/) {
		$build_flags .= ' DEBUG=1 DEBUG_NO_METER=1';
	}

	my $docker_cmd = join(" ",
		"docker run --rm",
		"-e SERIAL=$serial",
		"-e KEY=$key",
		"-e BUILD_FLAGS=\"$build_flags\"",
		"-v firmware_release:" . RELEASE_DIR,
		DOCKER_IMAGE
	);

	print "Running: $docker_cmd\n";

	my $success;
	my $exit_code;

	eval {
		system($docker_cmd);
		$exit_code = $? >> 8;
		$success = ($exit_code == 0);

		if (!$success) {
			warn "Build failed for $serial\n";
		}

		if ($success) {

			prepare_release_structure($serial, $fs_version);
			generate_manifest($serial, $sw_version, $fs_version);

			# Create meta.json
			my $dir = RELEASE_DIR . "/$serial/$fs_version";
			make_path($dir);

			my $meta = {
				serial     => $serial,
				sw_version => $sw_version,
				built_at   => time(),
			};

			open(my $fh, ">", "$dir/meta.json")
				or die "Cannot write meta.json: $!";

			print $fh encode_json($meta);
			close($fh);

			generate_firmware_index();
		}
	};

	my $err = $@;

	# always release lock
	$redis->del($lock_key);

	die $err if $err;

	return {
		serial => $serial,
		success => $success ? 1 : 0,
		exit_code => $exit_code
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
		name => "$serial ($sw_version)",
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
		my $meta_path = "$serial/$target/meta.json";

		if (-f RELEASE_DIR . "/$manifest_path") {

			my $name;

			if (-f RELEASE_DIR . "/$meta_path") {

				open(my $fh, "<", RELEASE_DIR . "/$meta_path");
				local $/;
				my $json_text = <$fh>;
				close($fh);

				my $meta = decode_json($json_text);

				$name = "$serial ($meta->{sw_version})";
			}
			else {
				$name = "$serial ($target)";
			}

			push @firmwares, {
				name => $name,
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
