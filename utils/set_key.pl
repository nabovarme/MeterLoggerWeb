#!/usr/bin/perl

use strict;
use warnings;

use Getopt::Long qw(GetOptions);

use Nabovarme::SetKey;
use Nabovarme::Utils;

my $log_file;

GetOptions(
	'l|log-file:o' => \$log_file,
) or log_die("Usage: $0 [-l[=LOGFILE]] <serial> [serial ...]\n");

if (defined($log_file)) {
	$log_file = 'meter_key_changes.log' if $log_file eq '';
} else {
	undef $log_file;
}

log_die("Usage: $0 [-l[=LOGFILE]] <serial> [serial ...]\n")
	if !@ARGV;

my @serials = @ARGV;

my %args;
$args{log_file} = $log_file if defined($log_file);

my $set_key = Nabovarme::SetKey->new(%args);

my $failed = 0;

for my $serial (@serials) {
	eval {
		$set_key->set_key($serial);
	};

	if ($@) {
		my $error = $@;
		chomp($error);

		log_warn("Failed to change key for meter $serial: $error");
		$failed++;
	}

	print "\n";
}

if ($failed) {
	log_die(
		"Key change failed for $failed of "
		. scalar(@serials) . " meter(s).\n"
	);
}

log_info("All key changes completed successfully.");
