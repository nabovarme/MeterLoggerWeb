#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
use Fcntl ':flock';  # For manual file locking
use File::Basename;

use Nabovarme::Db;
use Nabovarme::Utils;
use Nabovarme::EnergyEstimator;

# === LOCKING ===
my $script_name = basename($0);
my $lockfile = "/tmp/$script_name.lock";
open(my $fh, ">", $lockfile) or log_die("Cannot open lock file $lockfile: $!");
flock($fh, LOCK_EX | LOCK_NB) or log_die("Another instance is already running. Exiting.");
print $fh "$$\n";  # Write current PID to the lock file

# Connect to database
my $dbh = Nabovarme::Db->my_connect;
log_die("DB connection failed: $!") unless $dbh;

# Fetch all enabled meters
my $sth = $dbh->prepare(
	"SELECT serial FROM meters WHERE enabled = 1"
);
$sth->execute();

while (my ($serial) = $sth->fetchrow_array) {
	# Calculate remaining values using Utils
	my $est = Nabovarme::EnergyEstimator::estimate_remaining_energy($dbh, $serial);
}

# === UNLOCKING ===
# Clean up lock file after successful run
close($fh);
unlink $lockfile;
