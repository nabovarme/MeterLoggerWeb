#!/usr/bin/perl

use strict;
use warnings;

use JSON qw(encode_json);
use Digest::MD5 qw(md5_hex);
use File::Path qw(make_path);
use File::Copy qw(move);
use Fcntl qw(:flock);
use POSIX qw(strftime);
use FindBin;
use Getopt::Long qw(GetOptions);
use lib qw(/usr/local/share/perl);
use Nabovarme::Db;
use Nabovarme::FirmwareBuilder qw(build_flags_from_sw_version);

use constant DOCKER_IMAGE => 'firmware_sdk:latest';
use constant RELEASE_DIR => '/home/meterlogger/firmware';

$| = 1;

sub usage {
	die "Usage: $0 [--dry-run] <serial>\n";
}

my $dry_run = 0;
GetOptions('n|dry-run' => \$dry_run) or usage();
my $serial = shift @ARGV;
usage() unless defined $serial && $serial =~ /^\d+$/ && !@ARGV;

my $serial_dir = RELEASE_DIR . "/$serial";

my $dbh = Nabovarme::Db->my_connect
	or die "Database connection failed\n";

my $sth = $dbh->prepare(q{
	SELECT `serial`, `info`, `sw_version`, `key`
	FROM meters
	WHERE serial = ?
});
$sth->execute($serial);
my $meter = $sth->fetchrow_hashref
	or die "No meter found for serial $serial\n";
$sth->finish;
$dbh->disconnect;

my $info = $meter->{info} // '';
my $key = $meter->{key} // '';
my $build_flags = build_flags_from_sw_version($meter->{sw_version}) // '';

sub display_command {
	my (@cmd) = @_;
	return join(' ', map { /[^a-zA-Z0-9_.,:\/=+-]/ ? "'" . ($_ =~ s/'/'\\''/gr) . "'" : $_ } @cmd);
}

sub run_command {
	my (@cmd) = @_;
	my $display = display_command(@cmd);
	print "+ $display\n";
	my $status = system(@cmd);
	die "Failed to execute command: $!\n" if $status == -1;
	die "Command failed (" . ($status >> 8) . "): $display\n" if $status != 0;
}

sub docker_output {
	my (@cmd) = @_;
	open(my $fh, '-|', @cmd) or die "Cannot execute @cmd: $!\n";
	local $/;
	my $output = <$fh> // '';
	close($fh) or die "Command failed: @cmd\n";
	$output =~ s/[\r\n]+\z//;
	return $output;
}

my $branch = docker_output('docker', 'run', '--rm', DOCKER_IMAGE,
	'git', '-C', '/meterlogger/MeterLogger', 'rev-parse', '--abbrev-ref', 'HEAD');
my $count = docker_output('docker', 'run', '--rm', DOCKER_IMAGE,
	'git', '-C', '/meterlogger/MeterLogger', 'rev-list', 'HEAD', '--count');
my $desc = docker_output('docker', 'run', '--rm', DOCKER_IMAGE,
	'git', '-C', '/meterlogger/MeterLogger', 'describe', '--abbrev=4', '--dirty', '--always');
my $git_version = "$branch-$count-$desc";

my $config_hash = substr(md5_hex($build_flags . ':' . $key), 0, 6);
my $fs_version = $git_version;
$fs_version =~ s/[^a-zA-Z0-9._-]/_/g;
$fs_version = 'unknown' unless length $fs_version;
$fs_version .= "-$config_hash-" . strftime('%Y%m%d%H%M%S', localtime) . "-$$";

my $version_dir = "$serial_dir/$fs_version";

my $container_name = "firmware_sdk_build_${serial}_$$";
my @docker_args = (
	'docker', 'run', '--rm', '--name', $container_name,
	'-e', "SERIAL=$serial",
	'-e', "KEY=$key",
	'-e', "BUILD_FLAGS=$build_flags",
);

# Pass each build flag as its own environment variable for Make.
for my $flag (split /\s+/, $build_flags) {
	push @docker_args, ('-e', $flag) if length $flag;
}

push @docker_args, (
	'-v', 'firmware_release:/meterlogger/MeterLogger/release',
	DOCKER_IMAGE,
	# Override CMD to run the standard entrypoint, THEN manually copy the .out files
	'/bin/bash', '-c', 
	"/docker-entrypoint.sh && cp build_ota/app_slot0.out release/$serial/ && cp build_ota/app_slot1.out release/$serial/"
);

print "Firmware build parameters for meter $serial ($info)\n";
print "Firmware version: $git_version\n";
print "Docker image: " . DOCKER_IMAGE . "\n";
print "Release directory: $version_dir\n";
print "Docker command: " . display_command(@docker_args) . "\n";
print "Build parameters: $build_flags SERIAL=$serial KEY=$key\n";

if ($dry_run) {
	print "Dry run: no build started and no release files changed.\n";
	exit 0;
}

# Serialize builds started by this utility for the same meter.
make_path($serial_dir);
open(my $lock_fh, '>', "$serial_dir/.build.lock")
	or die "Cannot open build lock: $!\n";
flock($lock_fh, LOCK_EX)
	or die "Cannot lock meter $serial: $!\n";

mkdir($version_dir) or die "Cannot create unique release directory $version_dir: $!\n";

my $ok = eval {
	run_command(@docker_args);

	my @artifacts = qw(
		app_slot0.out
		app_slot1.out
		rboot.bin
		user1.bin
		user2.bin
		user1.ota.bin
		user2.ota.bin
		webpages.espfs
		esp_init_data_default_112th_byte_0x03.bin
		blank.bin
		user1.bin.sha256
		user2.bin.sha256
		user1.ota.bin.sha256
		user2.ota.bin.sha256
	);

	for my $artifact (@artifacts) {
		my $src = "$serial_dir/$artifact";
		my $dst = "$version_dir/$artifact";
		die "Required build artifact missing: $src\n" unless -f $src;
		move($src, $dst) or die "Cannot move $src to $dst: $!\n";
	}

	my $manifest = {
		name => "$info $serial ($git_version) [rBoot OTA]",
		version => $git_version,
		builds => [{
			chipFamily => 'ESP8266',
			parts => [
				{ path => 'rboot.bin', offset => 0x00000 },
				{ path => 'blank.bin', offset => 0x01000 },
				{ path => 'user1.bin', offset => 0x02000 },
				{ path => 'webpages.espfs', offset => 0x7C000 },
				{ path => 'esp_init_data_default_112th_byte_0x03.bin', offset => 0xFC000 },
				{ path => 'blank.bin', offset => 0xFE000 },
			],
		}],
	};

	open(my $manifest_fh, '>', "$version_dir/manifest.json")
		or die "Cannot write manifest.json: $!\n";
	print {$manifest_fh} encode_json($manifest);
	close($manifest_fh) or die "Cannot close manifest.json: $!\n";

	my $meta = {
		serial => $serial,
		info => $info,
		sw_version => $git_version,
		build_flags => $build_flags,
		built_at => time(),
	};
	open(my $meta_fh, '>', "$version_dir/meta.json")
		or die "Cannot write meta.json: $!\n";
	print {$meta_fh} encode_json($meta);
	close($meta_fh) or die "Cannot close meta.json: $!\n";

	# Point latest at this release after all artifacts and metadata are ready.
	my $latest = "$serial_dir/latest";
	unlink($latest) if -l $latest || -e $latest;
	symlink($fs_version, $latest) or die "Cannot create latest symlink: $!\n";

	print "Build completed successfully.\nRelease: $version_dir\n";
	1;
};

if (!$ok) {
	my $error = $@ || 'Unknown build error';
	warn "Build failed for meter $serial: $error";
	die $error;
}

exit 0;
