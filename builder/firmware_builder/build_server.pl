#!/usr/bin/perl -w

use strict;
use warnings;

use JSON;
use Redis;

use File::Path qw(make_path rmtree);
use File::Copy qw(move);
use IO::Handle;

use lib qw( /usr/local/share/perl );
use Nabovarme::Db;

use constant DOCKER_IMAGE      => 'firmware_sdk:latest';
use constant SOURCE_DIR        => '/meterlogger/MeterLogger';
use constant RELEASE_DIR       => '/meterlogger/MeterLogger/release';
use constant SYNC_INTERVAL     => 60; # Run DB sync check every 60 seconds

my $REDIS_QUEUE = "firmware_build_queue";
my $REDIS_TRIGGER = "firmware_build_trigger";
my $REDIS_ACTIVE_BATCHES = "firmware_active_batches";
my $REDIS_PENDING_TRIGGERS = "firmware_pending_triggers";
my $REDIS_JOBS_TOTAL = "firmware_jobs_total";
my $REDIS_JOBS_DONE = "firmware_jobs_completed";
my $REDIS_JOBS_SKIP = "firmware_jobs_skipped";
my $REDIS_JOBS_FAIL = "firmware_jobs_failed";
my $REDIS_BUILD_LOCK = "build-lock";

STDOUT->autoflush(1);
STDERR->autoflush(1);

# Graceful shutdown flag
my $running = 1;

# Handle shutdown signals for main process
$SIG{TERM} = sub {
	print "Main process received SIGTERM, shutting down...\n";
	$running = 0;
};

$SIG{INT} = sub {
	print "Main process received SIGINT, shutting down...\n";
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

my @worker_pids;

for (1..$workers) {
	my $worker_id = $_;

	my $pid = fork();

	if (!defined $pid) {
		die "Failed to fork worker $worker_id: $!";
	}

	if ($pid == 0) {

		# Child process gets its own Redis connection
		my $redis = Redis->new(
			server => "$redis_host:$redis_port",
		);

		# Child-local running flag
		my $running = 1;

		# IMPORTANT: child must handle shutdown signals
		$SIG{TERM} = sub {
			print "Worker $$ received TERM\n";
			$running = 0;
		};

		$SIG{INT} = sub {
			print "Worker $$ received INT\n";
			$running = 0;
		};

		print "Worker $worker_id started (pid $$)\n";

		while ($running) {

			my $job_json = $redis->blpop($REDIS_QUEUE, 1);
			next unless $job_json;

			# parent may be shutting down; don't start new work
			next unless $running;

			my ($queue, $data) = @$job_json;

			my $job = decode_json($data);

			print "Worker $$ building serial: $job->{serial} with Version/Suffix: $job->{version}\n";

			run_docker_build(
				$redis,
				$job->{serial},
				$job->{info},
				$job->{version},
				$job->{build_flags},
				$job->{batch_id}
			);
		}

		print "Worker $$ exiting cleanly\n";
		exit 0;
	}

	# parent tracks PID
	push @worker_pids, $pid;
}

print "Workers started\n";

my $last_sync_time = 0;

# Trigger listener and database synchronization loop (parent)
while ($running) {

	# 1. Non-blocking check for manual Redis triggers (1 second timeout)
	my $data = $redis->blpop($REDIS_TRIGGER, 1);
	if ($data) {
		my (undef, $payload) = @$data;
		my $trigger = decode_json($payload);
		
		print "Received manual trigger: " . ($trigger->{reason} || "unknown") . " at " . scalar(localtime($trigger->{time})) . "\n";
		
		$redis->rpush($REDIS_PENDING_TRIGGERS, $payload);
		print "Trigger added to pending queue\n";
	}

	# 2. Check if a batch is currently active
	my $current_batch = $redis->lindex($REDIS_ACTIVE_BATCHES, 0);
	my $pending_count = $redis->llen($REDIS_PENDING_TRIGGERS) || 0;

	if ($current_batch) {
		# Existing batch is running, check completion status
		my $total = $redis->get("$REDIS_JOBS_TOTAL:$current_batch") || 0;
		my $done  = $redis->get("$REDIS_JOBS_DONE:$current_batch") || 0;
		my $skip  = $redis->get("$REDIS_JOBS_SKIP:$current_batch") || 0;
		my $fail  = $redis->get("$REDIS_JOBS_FAIL:$current_batch") || 0;
		
		my $processed = $done + $skip + $fail;
		print "Batch active: $current_batch. Progress: $processed/$total ($pending_count batches pending)\n" if $processed % 5 == 0 || $processed == $total;

		if ($total > 0 && $processed >= $total) {
			print "Batch $current_batch fully completed ($done done, $skip skipped, $fail failed).\n";
			
			# Generate index and clean up batch-specific keys
			generate_firmware_index();
			
			$redis->del("$REDIS_JOBS_TOTAL:$current_batch");
			$redis->del("$REDIS_JOBS_DONE:$current_batch");
			$redis->del("$REDIS_JOBS_SKIP:$current_batch");
			$redis->del("$REDIS_JOBS_FAIL:$current_batch");

			$redis->lpop($REDIS_ACTIVE_BATCHES);
			print "Batch $current_batch removed from active queue.\n";
		}
	} else {
		# No active batch, try to start the next pending trigger
		my $next_payload = $redis->lpop($REDIS_PENDING_TRIGGERS);
		if ($next_payload) {
			my $trigger = decode_json($next_payload);
			print "Starting new batch from pending triggers. ($pending_count remaining in queue)\n";
			process_build($trigger, 1);
		}
		elsif (time() - $last_sync_time >= SYNC_INTERVAL) {
			$last_sync_time = time();
			print "Running scheduled 1-minute database sync check...\n";
			process_build(undef, 0);
		}
	}

	last unless $running;
	sleep 1 if !$current_batch;
}

# =========================
# GRACEFUL SHUTDOWN
# =========================

print "Stopping workers...\n";

kill 'TERM', @worker_pids;

foreach my $pid (@worker_pids) {
	waitpid($pid, 0);
	print "Worker $pid exited\n";
}

print "All workers shut down cleanly\n";
cleanup_all_batches();

# =========================
# OPERATIONAL UTILITIES
# =========================

sub rebuild_firmware_sdk {
	print "Rebuilding firmware_sdk via docker on host...\n";

	my $cmd = "docker build --build-arg CACHEBUST=\$(date +%s) -t firmware_sdk:latest -f /docker_root/builder/firmware_sdk/Dockerfile /docker_root 2>&1";

	# Open a real-time command pipeline read stream to output logs as they happen
	open(my $ph, "-|", $cmd)
		or die "Failed to execute docker build pipeline link: $!";

	for (my $line = <$ph>) {
		print $line;
	}

	close($ph);
	my $exit_code = $? >> 8;

	if ($exit_code != 0) {
		die "Failed to rebuild firmware_sdk (Exit code: $exit_code)";
	}

	print "firmware_sdk rebuilt successfully\n";
}

sub get_git_version_from_docker {
	my $cmd = "docker run --rm " . DOCKER_IMAGE .
		" git -C " . SOURCE_DIR . " rev-parse --abbrev-ref HEAD";

	my $branch = `$cmd`; chomp $branch;

	$cmd = "docker run --rm " . DOCKER_IMAGE .
		" git -C " . SOURCE_DIR . " rev-list HEAD --count";

	my $count = `$cmd`; chomp $count;

	$cmd = "docker run --rm " . DOCKER_IMAGE .
		" git -C " . SOURCE_DIR . " describe --abbrev=4 --dirty --always";

	my $desc = `$cmd`; chomp $desc;

	return "$branch-$count-$desc";
}

sub build_flags_from_sw_version {
	my ($sw_version) = @_;
	return 'AP=1' unless defined $sw_version;

	my @flags = ('AP=1');

	# Protocol / Hardware Mappings Directives
	push @flags, 'EN61107=1'        if $sw_version =~ /MC_66C/;
	push @flags, 'MC_66B=1'         if $sw_version =~ /MC_66B/;
	push @flags, 'IMPULSE=1'        if $sw_version =~ /IMPULSE/;

	# Retro-compatibility check for base-profile matches
	push @flags, 'MC_66B=1'         if $sw_version =~ /MC-B/;
	push @flags, 'EN61107=1'        if $sw_version =~ /MC/ && $sw_version !~ /MC_66B/;

	# Functional Logic Modifiers
	push @flags, 'FLOW_METER=1'     if $sw_version =~ /FLOW_METER/;
	push @flags, 'AUTO_CLOSE=0'     if $sw_version =~ /NO_AUTO_CLOSE/;
	push @flags, 'NO_CRON=1'        if $sw_version =~ /NO_CRON/;

	# Electrical Actuator Configuration States
	push @flags, 'THERMO_NO=1'      if $sw_version =~ /THERMO_NO/;
	push @flags, 'THERMO_ON_AC_2=1' if $sw_version =~ /THERMO_ON_AC_2/;
	push @flags, 'LED_ON_AC=1'      if $sw_version =~ /LED_ON_AC/;
	push @flags, 'AC_TEST=1'        if $sw_version =~ /AC_TEST/;

	# Diagnostic Engine / Mock Environment Overrides
	push @flags, 'DEBUG=1'                if $sw_version =~ /DEBUG/ && $sw_version !~ /DEBUG_NO_METER/ && $sw_version !~ /DEBUG_STACK_TRACE/;
	push @flags, 'DEBUG=1 DEBUG_NO_METER=1' if $sw_version =~ /NO_METER/;
	push @flags, 'DEBUG_STACK_TRACE=1'    if $sw_version =~ /DEBUG_STACK_TRACE/;

	return join(' ', @flags);
}

sub print_progress {
	my ($batch_id) = @_;

	my $total = $redis->get("$REDIS_JOBS_TOTAL:$batch_id") || 0;
	my $done  = $redis->get("$REDIS_JOBS_DONE:$batch_id") || 0;
	my $skip  = $redis->get("$REDIS_JOBS_SKIP:$batch_id") || 0;
	my $fail  = $redis->get("$REDIS_JOBS_FAIL:$batch_id") || 0;

	return if $total == 0;

	my $percent = int((($done + $skip + $fail) / $total) * 100);

	print "Progress: $done done, $skip skipped, $fail failed ($percent%)\n";

	if (($done + $skip + $fail) >= $total) {
		print "ALL JOBS COMPLETED ($batch_id)\n";
	}
}

sub process_build {
	my ($trigger, $force_full_rebuild) = @_;
	$force_full_rebuild //= 0;

	my $dbh = Nabovarme::Db->my_connect
		or die "DB connection failed";

	my $sth = $dbh->prepare("
		SELECT `serial`, `info`, `sw_version`
		FROM meters
		WHERE enabled = 1
		ORDER BY serial
	");

	$sth->execute;

	my $git_version = get_git_version_from_docker();

	my $fs_version = $git_version;
	$fs_version =~ s/[^a-zA-Z0-9._-]/_/g;
	$fs_version = 'unknown' if !$fs_version;

	my %active_db_meters;
	my @jobs_to_queue;
	my $job_count = 0;

	while (my $row = $sth->fetchrow_hashref) {
		$active_db_meters{$row->{serial}} = 1;

		if (!$force_full_rebuild) {
			my $firmware_path = RELEASE_DIR . "/$row->{serial}/$fs_version/manifest.json";
			if (-f $firmware_path) {
				next;
			}
		}

		push @jobs_to_queue, $row;
		$job_count++;
	}

	if (opendir(my $dh, RELEASE_DIR)) {
		while (my $dir_entry = readdir($dh)) {
			next if ($dir_entry =~ /^\./);
			next if ($dir_entry eq 'firmwares.json');

			if ($dir_entry =~ /^\d+$/) {
				if (!$active_db_meters{$dir_entry}) {
					print "Sync Purge: Meter $dir_entry not found active in database. Deleting local firmware tree...\n";
					rmtree(RELEASE_DIR . "/$dir_entry");
				}
			}
		}
		closedir($dh);
	}

	if ($job_count == 0) {
		if (!$force_full_rebuild) {
			generate_firmware_index();
		}
		return;
	}

	if ($force_full_rebuild) {
		rebuild_firmware_sdk();
	}

	my $batch_id = time();
	
	$redis->rpush($REDIS_ACTIVE_BATCHES, $batch_id);

	my $total_key = "$REDIS_JOBS_TOTAL:$batch_id";
	my $done_key  = "$REDIS_JOBS_DONE:$batch_id";
	my $skip_key  = "$REDIS_JOBS_SKIP:$batch_id";
	my $fail_key  = "$REDIS_JOBS_FAIL:$batch_id";

	$redis->set($total_key, $job_count);
	$redis->set($done_key, 0);
	$redis->set($skip_key, 0);
	$redis->set($fail_key, 0);

	print "Jobs to enqueue: $job_count\n";

	foreach my $row (@jobs_to_queue) {

		my $build_flags = build_flags_from_sw_version($row->{sw_version});

		my $job = encode_json({
			serial       => $row->{serial},
			info         => $row->{info},
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
	my ($redis, $serial, $info, $version, $build_flags, $batch_id) = @_;

	my $lock_key = "$REDIS_BUILD_LOCK:$serial";

	my $total_key = "$REDIS_JOBS_TOTAL:$batch_id";
	my $done_key  = "$REDIS_JOBS_DONE:$batch_id";
	my $skip_key  = "$REDIS_JOBS_SKIP:$batch_id";
	my $fail_key  = "$REDIS_JOBS_FAIL:$batch_id";

	my $got_lock = $redis->set($lock_key, 1, 'NX', 'EX', 7200);

	if (!$got_lock) {
		print "Skipping $serial (already in progress)\n";
		$redis->incr($skip_key);
		print_progress($batch_id);
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

	my $fs_version = $sw_version;
	$fs_version =~ s/[^a-zA-Z0-9._-]/_/g;
	$fs_version = 'unknown' if !$fs_version;

	my $firmware_path = RELEASE_DIR . "/$serial/$fs_version/manifest.json";

	if (-f $firmware_path) {
		print "Skipping build for $serial (already exists)\n";

		$redis->del($lock_key);
		$redis->incr($skip_key);

		print_progress($batch_id);
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
			$redis->incr($fail_key);
		}

		if ($success) {
			prepare_release_structure($serial, $fs_version);
			generate_manifest($serial, $info, $sw_version, $fs_version);

			my $dir = RELEASE_DIR . "/$serial/$fs_version";
			make_path($dir);

			my $meta = {
				serial      => $serial,
				info        => $info,
				sw_version  => $sw_version,
				build_flags => $build_flags,
				built_at    => time(),
			};

			open(my $fh, ">", "$dir/meta.json")
				or die "Cannot write meta.json: $!";

			print $fh encode_json($meta);
			close($fh);

			$redis->incr($done_key);
		}
	};

	my $err = $@;

	# always release lock
	$redis->del($lock_key);

	print_progress($batch_id);

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

	make_path($version_dir);

	# Look for components in the isolated serial directory matching Makefile updates
	my $isolated_src_dir = "$base_dir/$serial";

	my @components = (
		{ src => "$isolated_src_dir/0x00000.bin", dst => "$version_dir/0x00000.bin" },
		{ src => "$isolated_src_dir/0x10000.bin", dst => "$version_dir/0x10000.bin" },
		{ src => "$isolated_src_dir/webpages.espfs", dst => "$version_dir/webpages.espfs" },
		{ src => "$isolated_src_dir/esp_init_data_default_112th_byte_0x03.bin", dst => "$version_dir/esp_init_data_default_112th_byte_0x03.bin" },
		{ src => "$isolated_src_dir/blank.bin", dst => "$version_dir/blank.bin" }
	);

	foreach my $cmp (@components) {
		unlink $cmp->{dst} if -f $cmp->{dst};

		if (-f $cmp->{src}) {
			move($cmp->{src}, $cmp->{dst})
				or die "Cannot migrate build component asset from $cmp->{src} to $cmp->{dst}: $!";
		} else {
			die "Required compilation element not found: $cmp->{src}";
		}
	}

	# Clean up the intermediate staging serial subdirectory context cleanly
	rmdir($isolated_src_dir);

	my $latest_link = "$serial_dir/latest";
	unlink $latest_link if -l $latest_link || -e $latest_link;

	symlink($fs_version, $latest_link)
		or warn "Could not create symlink tracking pointer link: $!";
}

sub generate_manifest {
	my ($serial, $info, $sw_version, $fs_version) = @_;

	my $dir = RELEASE_DIR . "/$serial/$fs_version";

	my $manifest = {
		name => "$info $serial ($sw_version) [Multi-Segment]",
		version => $sw_version || 'unknown',
		builds => [
			{
				chipFamily => "ESP8266",
				parts => [
					{
						path => "0x00000.bin",
						offset => 0x00000
					},
					{
						path => "0x10000.bin",
						offset => 0x10000
					},
					{
						path => "webpages.espfs",
						offset => 0x60000
					},
					{
						path => "esp_init_data_default_112th_byte_0x03.bin",
						offset => 0xFC000
					},
					{
						path => "blank.bin",
						offset => 0xFE000
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

# --- ENHANCED DYNAMIC DROPDOWN MENU FORMATTING ENGINE ---
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
				
				my $display_info = $meta->{info} || 'Meter';
				my $formatted_version = $meta->{sw_version} || $version;
				my $bracket_flags = $meta->{build_flags} || '';

				# Parse the path layout: master-1462-a35f2-custom-OPTIONS...
				if ($version =~ /^master-.*-custom/) {
					# Isolate the exact matching segment block context cleanly for display: master-1462-a35f2
					if ($version =~ /^(master-[^-]+-[^-]+)-custom/) {
						$formatted_version = $1;
					} else {
						$formatted_version = "master-custom";
					}
					$bracket_flags = $bracket_flags ? "CUSTOM $bracket_flags" : "CUSTOM";
				}

				# Structure formatting output layout string precisely
				$name = "$serial ~ $display_info ($formatted_version)";
				if ($bracket_flags) {
					$name .= " [$bracket_flags]";
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

sub cleanup_all_batches {
	my @patterns = (
		"$REDIS_JOBS_TOTAL:*",
		"$REDIS_JOBS_DONE:*",
		"$REDIS_JOBS_SKIP:*",
		"$REDIS_JOBS_FAIL:*",
		$REDIS_QUEUE,
		$REDIS_ACTIVE_BATCHES,
		"$REDIS_BUILD_LOCK:*",
	);

	foreach my $pattern (@patterns) {

		my $cursor = 0;

		do {
			my ($new_cursor, $keys) = $redis->scan($cursor, MATCH => $pattern, COUNT => 1000);
			$cursor = $new_cursor;

			foreach my $key (@$keys) {
				print "Deleting key: $key\n";
				$redis->del($key);
			}

		} while ($cursor != 0);
	}

	print "Cleaned up all firmware-related Redis keys\n";
}

1;
