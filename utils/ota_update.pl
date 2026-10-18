
#!/usr/bin/perl -w

use strict;
use warnings;
use FindBin;
use Getopt::Long qw(GetOptions);

use Nabovarme::OTA;
use Nabovarme::Db;

# Ensure stdout flushes immediately
$| = 1;

sub print_usage {
	print << "EOF";
Usage: $0 [options] <serial> [serial ...]

Options:
  -v, --version VERSION   Firmware version to install (default: latest)
  -c, --confirm           Query current running ROM version and confirm it
  -u, --unattended        Run without interactive prompts; confirm unconfirmed ROMs
  -R, --unattended-revert Run unattended; revert unconfirmed ROMs before updating
  -h, --help              Show this help message

Examples:
  $0 9999995
  $0 9999995 9999996 9999997
  $0 --version 20261013_152158 9999995 9999996
  $0 --confirm 9999995 9999996
  $0 --unattended 9999995 9999996
  $0 --unattended-revert 9999995 9999996
EOF
	exit 0;
}

my $help = 0;
my $confirm_only = 0;
my $unattended = 0;
my $unattended_revert = 0;
my $version = 'latest';

GetOptions(
	'help|h'              => \$help,
	'confirm|c'           => \$confirm_only,
	'unattended|u'         => \$unattended,
	'unattended-revert|R' => \$unattended_revert,
	'version|v=s'         => \$version,
) or die "Error in command line arguments\n";

print_usage() if $help;

die "Error: --unattended-revert cannot be used with --confirm.\n"
	if $confirm_only && $unattended_revert;

my @serials = @ARGV;
print_usage() if !@serials;

my @failed;
my @skipped;
my $interrupted = 0;
my $total = scalar @serials;

$SIG{INT} = sub {
	if (!$interrupted) {
		$interrupted = 1;
		print STDERR "\nWARNING: Ctrl+C received. Stopping after the current operation...\n";
		print STDERR "Press Ctrl+C again to abort immediately.\n";
	}
	else {
		print STDERR "\nAborted by user (second Ctrl+C).\n";
		exit(130);
	}
};

print "Connecting to database...\n";

my $ota = Nabovarme::OTA->new();

# Fetch meter information for user-facing output.
my $dbh = Nabovarme::Db->my_connect
	or die "Failed to connect to database to fetch meter information\n";

my $info_sth = $dbh->prepare(qq[
	SELECT `info`
	FROM meters
	WHERE `serial` = ?
	LIMIT 1
]);

for my $i (0 .. $#serials) {
	last if $interrupted;

	my $serial = $serials[$i];

	$info_sth->execute($serial);
	my ($info) = $info_sth->fetchrow_array;
	$info_sth->finish;

	my $meter_label = $serial;
	$meter_label .= " - $info" if defined $info && $info ne '';

	if ($total > 1) {
		print "\n", "=" x 60, "\n";
		print "Meter $meter_label (" . ($i + 1) . "/$total)\n";
		print "=" x 60, "\n";
	} else {
		print "Meter $meter_label\n";
	}

	my $ok;
	my $error;

	eval {
		if ($confirm_only) {
			$ok = $ota->confirm(
				$serial,
				unattended => $unattended,
				on_prompt  => sub {
					print "Are you sure you want to confirm this running ROM permanently? [y/N]: ";
					my $ans;
					{
						# Safe instant abort only while waiting at the prompt
						local $SIG{INT} = sub {
							print "\nAborted by user.\n";
							exit(130);
						};
						$ans = <STDIN>;
					}
					chomp($ans) if defined $ans;
					return $ans // 'n';
				}
			);
		}
		else {
			$ok = $ota->update(
				$serial,
				version           => $version,
				unattended        => ($unattended || $unattended_revert),
				unattended_revert => $unattended_revert,
				on_unconfirmed    => sub {
					print "Options:\n";
					print "  [C] Confirm the running ROM and retry OTA (Default)\n";
					print "  [R] Restart meter (reverts to previous ROM) and retry OTA\n";
					print "  [A] Abort\n";
					print "Choose an action [C/r/a]: ";
					my $ans;
					{
						# Safe instant abort only while waiting at the prompt
						local $SIG{INT} = sub {
							print "\nAborted by user.\n";
							exit(130);
						};
						$ans = <STDIN>;
					}
					chomp($ans) if defined $ans;
					return $ans // 'c';
				}
			);
		}

		1;
	} or do {
		$error = $@ || "Unknown error.\n";
	};

	if (defined($error) && $error ne '') {
		print STDERR "ERROR: Meter $meter_label failed: $error";
		print STDERR "\n" if $error !~ /\n\z/;

		push @failed, {
			serial => $serial,
			label  => $meter_label,
			error  => $error
		};
	}
	elsif (!$ok) {
		push @skipped, $meter_label;
	}
}

$dbh->disconnect();

print "\n", "=" x 60, "\n";
print "Batch processing completed";
print " (interrupted by user)" if $interrupted;
print ".\n";

if (@failed) {
	print "\nFailed " . ($confirm_only ? "confirmations" : "upgrades") . ":\n";

	for my $failure (@failed) {
		my $error = $failure->{error};
		$error =~ s/\s+\z//;

		print "  Meter $failure->{label}: $error\n";
	}
}
else {
	print "No " . ($confirm_only ? "confirmation failures" : "upgrade failures") . ".\n";
}

if (@skipped) {
	print "\nSkipped meters: " . join(", ", @skipped) . "\n";
}

if ($interrupted) {
	print "\nBatch interrupted; remaining meters were not processed.\n";
}

exit($interrupted ? 130 : @failed ? 1 : 0);
