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
  -u, --unattended        Run without interactive prompts
  -h, --help              Show this help message

Examples:
  $0 9999995
  $0 9999995 9999996 9999997
  $0 --version 20261013_152158 9999995 9999996
  $0 --confirm 9999995 9999996
  $0 --unattended 9999995 9999996
  $0 --unattended --confirm 9999995 9999996
EOF
	exit 0;
}

my $help = 0;
my $confirm_only = 0;
my $unattended = 0;
my $version = 'latest';

GetOptions(
	'help|h'        => \$help,
	'confirm|c'     => \$confirm_only,
	'unattended|u'  => \$unattended,
	'version|v=s'   => \$version,
) or die "Error in command line arguments\n";

print_usage() if $help;

my @serials = @ARGV;
print_usage() if !@serials;

my @failed;
my @skipped;
my $interrupted = 0;
my $total = scalar @serials;

$SIG{INT} = sub {
	if (!$interrupted) {
		$interrupted = 1;
		print STDERR "\nInterrupted by user (Ctrl+C). Stopping after the current operation...\n";
	}
};

print "Connecting to database...\n";

my $ota = Nabovarme::OTA->new();

for my $i (0 .. $#serials) {
	last if $interrupted;

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
			$ok = $ota->confirm(
				$serial,
				unattended => $unattended
			);
		}
		else {
			$ok = $ota->update(
				$serial,
				version => $version,
				unattended => $unattended
			);
		}

		1;
	} or do {
		$error = $@ || "Unknown error.\n";
	};

	if (defined($error) && $error ne '') {
		print STDERR "ERROR: Meter $serial failed: $error";
		print STDERR "\n" if $error !~ /\n\z/;

		push @failed, {
			serial => $serial,
			error => $error
		};
	}
	elsif (!$ok) {
		push @skipped, $serial;
	}
}

print "\n", "=" x 60, "\n";
print "Batch processing completed";
print " (interrupted by user)" if $interrupted;
print ".\n";

if (@failed) {
	print "\nFailed " . ($confirm_only ? "confirmations" : "upgrades") . ":\n";

	for my $failure (@failed) {
		my $error = $failure->{error};
		$error =~ s/\s+\z//;

		print "  Meter $failure->{serial}: $error\n";
	}
}
else {
	print "No " . ($confirm_only ? "confirmation failures" : "upgrade failures") . ".\n";
}

if (@skipped) {
	print "\nSkipped meters: " . join(", ", @skipped) . "\n";
}

if ($interrupted) {
	my $processed = $total - ($#serials + 1);
	# The loop may have stopped before processing all requested meters.
	print "\nBatch interrupted; remaining meters were not processed.\n";
}

exit($interrupted ? 130 : @failed ? 1 : 0);
