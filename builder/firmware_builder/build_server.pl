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
use constant SOURCE_DIR => '/meterlogger/MeterLogger';
use constant RELEASE_DIR => '/meterlogger/MeterLogger/release';

my $REDIS_QUEUE = "firmware_build_queue";
my $REDIS_TRIGGER = "firmware_build_trigger";

STDOUT->autoflush(1);
STDERR->autoflush(1);

# Graceful shutdown flag
my $running = 1;

# Handle shutdown signals
$SIG{TERM} = sub {
	print "Received SIGTERM, shutting down...\n";
	$running = 0;
};

$SIG{INT} = sub {
	print "Received SIGINT, shutting down...\n";
	$running = 0;
};

# Redis connection (MAIN PROCESS ONLY)
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

		# Child process gets its own Redis connection
		my $redis = Redis->new(
			server => "$redis_host:$redis_port",
		);

		print "Worker $_ started (pid $$)\n";

		while ($running) {

			my $job_json = $redis->blpop($REDIS_QUEUE, 1);
			next unless $job_json;

			my ($queue, $data) = @$job_json;

			my $job = decode_json($data);

			print "Worker $$ building serial: $job->{serial}\n";

			run_docker_build(
				$redis,
				$job->{serial},
				$job->{version},
				$job->{build_flags},
				$job->{batch_id}
			);
		}

		exit;
	}
}

print "Workers started\n";

# Trigger listener
while ($running) {

	my $data = $redis->blpop($REDIS_TRIGGER, 1);
	next unless $data;

	my (undef, $payload) = @$data;

	my $trigger = decode_json($payload);

	print "Processing build trigger\n";
	print "Starting job processing...\n";

	process_build($trigger);
}

sub rebuild_firmware_sdk {
	print "Rebuilding firmware_sdk via docker on host...\n";

	my $cmd = "docker build --build-arg CACHEBUST=\$(date +%s) -t firmware_sdk:latest -f /docker_root/builder/firmware_sdk/Dockerfile /docker_root";

	my $output = `$cmd 2>&1`;
	my $exit_code = $? >> 8;

	print "$output\n";

	if ($exit_code != 0) {
		die "Failed to rebuild firmware_sdk:\n$output";
	}

	print "firmware_sdk rebuilt successfully\n";
}

sub get_git_version_from_docker {
	my $cmd = "docker run --rm " . DOCKER_IMAGE .
		" git -C " . SOURCE_DIR . " rev-parse --abbrev-ref HEAD";

	my $branch = `$cmd`;
	chomp $branch;

	$cmd = "docker run --rm " . DOCKER_IMAGE .
		" git -C " . SOURCE_DIR . " rev-list HEAD --count";

	my $count = `$cmd`;
	chomp $count;

	$cmd = "docker run --rm " . DOCKER_IMAGE .
		" git -C " . SOURCE_DIR . " describe --abbrev=4 --dirty --always";

	my $desc = `$cmd`;
	chomp $desc;

	return "$branch-$count-$desc";
}

sub build_flags_from_sw_version {
	my ($sw_version) = @_;

	my $flags = 'AP=1';

	return $flags unless defined $sw_version;

	if ($sw_version =~ /NO_AUTO_CLOSE/) {
		$flags .= ' AUTO_CLOSE=0';
	}

	if ($sw_version =~ /NO_CRON/) {
		$flags .= ' NO_CRON=1';
	}

	if ($sw_version =~ /DEBUG_STACK_TRACE/) {
		$flags .= ' DEBUG_STACK_TRACE=1';
	}

	if ($sw_version =~ /THERMO_ON_AC_2/) {
		$flags .= ' THERMO_ON_AC_2=1';
	}

	if ($sw_version =~ /MC-B/) {
		$flags .= ' MC_66B=1';
	}
	elsif ($sw_version =~ /MC/) {
		$flags .= ' EN61107=1';
	}
	elsif ($sw_version =~ /NO_METER/) {
		$flags .= ' DEBUG=1 DEBUG_NO_METER=1';
	}

	return $flags;
}

sub print_progress {
	my ($batch_id) = @_;

	my $total = $redis->get("firmware_jobs_remaining:$batch_id") || 0;
	my $done  = $redis->get("firmware_jobs_completed:$batch_id") || 0;

	return if $total == 0;

	my $percent = int(($done / $total) * 100);

	print "Progress: $done/$total ($percent%)\n";
}

sub process_build {
	my ($trigger) = @_;

	rebuild_firmware_sdk();

	my $dbh = Nabovarme::Db->my_connect
		or die "DB connection failed";

	my $sth = $dbh->prepare("
		SELECT serial, sw_version
		FROM meters
		WHERE enabled = 1
		ORDER BY serial
	");

	$sth->execute;

	my $git_version = get_git_version_from_docker();

	my $batch_id = time();

	my $total_key = "firmware_jobs_remaining:$batch_id";
	my $done_key  = "firmware_jobs_completed:$batch_id";

	# count jobs
	my $job_count = 0;

	my @rows;
	while (my $row = $sth->fetchrow_hashref) {
		push @rows, $row;
		$job_count++;
	}

	# initialize counters early
	$redis->set($total_key, $job_count);
	$redis->set($done_key, 0);

	print "Jobs to enqueue: $job_count\n";

	# enqueue jobs
	foreach my $row (@rows) {

		my $build_flags = build_flags_from_sw_version($row->{sw_version});

		my $job = encode_json({
			serial       => $row->{serial},
			trigger_time => time(),
			version      => $git_version,
			build_flags  => $build_flags,
			batch_id     => $batch_id
		});

		$redis->rpush($REDIS_QUEUE, $job);
	}

	print "All jobs enqueued\n";
}

sub run_docker_build {
	my ($redis, $serial, $version, $build_flags, $batch_id) = @_;

	my $lock_key = "build-lock:$serial";

	my $total_key = "firmware_jobs_remaining:$batch_id";
	my $done_key  = "firmware_jobs_completed:$batch_id";

	# try to acquire lock
	my $got_lock = $redis->set($lock_key, 1, 'NX', 'EX', 7200);

	if (!$got_lock) {
		print "Skipping $serial (already in progress)\n";

		my $done = $redis->incr($done_key);
		print_progress($batch_id);

		if ($done == $redis->get($total_key)) {
			print "All jobs completed\n";
		}

		return;
	}

	my $dbh = Nabovarme::Db->my_connect
		or die "DB connection failed";

	my $sth = $dbh->prepare("
		SELECT `key`
		FROM meters
		WHERE serial = ?
	");

	$sth->execute($serial);

	my $row = $sth->fetchrow_hashref
		or die "No meter found for serial $serial";

	my $key = $row->{key};

	my $sw_version = $version;

	# filesystem safe version (ONLY for paths)
	my $fs_version = $sw_version;
	$fs_version =~ s/[^a-zA-Z0-9._-]/_/g;
	$fs_version = 'unknown' if !$fs_version;

	my $firmware_path = RELEASE_DIR . "/$serial/$fs_version/firmware.bin";

	# Skip if already built
	if (-f $firmware_path) {
		print "Skipping build for $serial (already exists)\n";
		$redis->del($lock_key);

		my $done = $redis->incr($done_key);
		print_progress($batch_id);

		if ($done == $redis->get($total_key)) {
			print "All jobs completed\n";
		}

		return;
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
				build_flags => $build_flags,
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

	my $done = $redis->incr($done_key);
	print_progress($batch_id);

	if ($done == $redis->get($total_key)) {
		print "All jobs completed\n";
	}

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

		my $serial_path = RELEASE_DIR . "/$serial";

		next unless -d $serial_path;

		opendir(my $v_dh, $serial_path) or next;

		while (my $version = readdir($v_dh)) {

			next if ($version =~ /^\./);
			next if ($version eq 'latest');

			my $manifest_path = "$serial_path/$version/manifest.json";
			my $meta_path     = "$serial_path/$version/meta.json";

			next unless -f $manifest_path;

			my $name;

			if (-f $meta_path) {
				open(my $fh, "<", $meta_path);
				local $/;
				my $json_text = <$fh>;
				close($fh);

				my $meta = decode_json($json_text);
				$name = "$serial ($meta->{sw_version})";

				if ($meta->{build_flags}) {
					$name .= " [$meta->{build_flags}]";
				}
			}
			else {
				$name = "$serial ($version)";
			}

			push @firmwares, {
				name    => $name,
				serial  => $serial,
				version => $version,
				path    => "$serial/$version/manifest.json",
			};
		}

		closedir($v_dh);
	}

	closedir($dh);

	open(my $fh, ">", RELEASE_DIR . "/firmwares.json")
		or die "Cannot write index";

	print $fh encode_json(\@firmwares);
	close($fh);
}
