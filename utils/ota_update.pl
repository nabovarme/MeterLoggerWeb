#!/usr/bin/perl -w

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use Getopt::Long qw(GetOptions);
use Nabovarme::OTA;

# Ensure stdout flushes immediately
$| = 1;

sub print_usage {
	print << "EOF";
Usage: $0 [options] <serial> [serial ...]

Options:
  -v, --version VERSION   Firmware version to install (default: latest)
  -c, --confirm           Query current running ROM version and confirm it
  -h, --help              Show this help message

Examples:
  $0 9999995
  $0 9999995 9999996 9999997
  $0 --version 20261013_152158 9999995 9999996
  $0 --confirm 9999995 9999996
EOF
	exit 0;
}

my $help = 0;
my $confirm_only = 0;
my $version = 'latest';

GetOptions(
	'help|h'      => \$help,
	'confirm|c'   => \$confirm_only,
	'version|v=s' => \$version,
) or die "Error in command line arguments\n";

print_usage() if $help;

my @serials = @ARGV;
print_usage() if !@serials;

print "Connecting to database...\n";

my $ota = Nabovarme::OTA->new();

my @failed;
my @skipped;
my $total = scalar @serials;

for my $i (0 .. $#serials) {
	my $serial = $serials[$i];

	if ($total > 1) {
		print "\n", "=" x 60, "\n";
		print "Meter $serial (" . ($i + 1) . "/$total)\n";
		print "=" x 60, "\n";
	}

	my $ok;
	my $error;

	eval {
		if ($confirm_only) {
			$ok = $ota->confirm($serial);
		}
		else {
			$ok = $ota->update(
				$serial,
				version => $version
			);
		}

		1;
	} or do {
		$error = $@ || "Unknown error.\n";
	};

	if (defined($error) && $error ne '') {
		print STDERR "ERROR: Meter $serial failed: $error";
		print STDERR "\n" if $error !~ /\n\z/;

		push @failed, $serial;
	}
	elsif (!$ok) {
		push @skipped, $serial;
	}
}

if ($total > 1) {
	print "\n", "=" x 60, "\n";
	print "Batch processing completed.\n";

	if (@failed) {
		print "Failed meters: " . join(", ", @failed) . "\n";
	}

	if (@skipped) {
		print "Skipped meters: " . join(", ", @skipped) . "\n";
	}

	if (!@failed && !@skipped) {
		print "All meters processed successfully.\n";
	}
}

exit(@failed ? 1 : 0);
