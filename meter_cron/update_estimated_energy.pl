#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
use Fcntl ':flock';  # For manual file locking

use Nabovarme::Db;
use Nabovarme::Utils;

# === LOCKING ===
my $script_name = basename($0);
my $lockfile = "/tmp/$script_name.lock";
open(my $fh, ">", $lockfile) or log_die("Cannot open lock file $lockfile: $!");
flock($fh, LOCK_EX | LOCK_NB) or log_die("Another instance is already running. Exiting.");
print $fh "$$\n";  # Write current PID to the lock file

# Connect to database
my $dbh = Nabovarme::Db->my_connect;
log_die("DB connection failed: $!") unless $dbh;

# Prepare update statement for time_remaining_hours only
my $update_sth = $dbh->prepare(
	"UPDATE meters SET time_remaining_hours = ? WHERE serial = ?"
);

# Fetch all enabled meters
my $sth = $dbh->prepare(
	"SELECT serial FROM meters WHERE enabled = 1"
);
$sth->execute();

while (my ($serial) = $sth->fetchrow_array) {

	# Calculate remaining values using Utils
	my $est = Nabovarme::Utils::estimate_remaining_energy($dbh, $serial);

	my $time_remaining_hours = $est->{time_remaining_hours};
	my $method_used           = $est->{method} || 'none';
	my $time_remaining_hours_formatted = defined $time_remaining_hours
		? sprintf("%.2f", $time_remaining_hours)
		: undef;

	# Update meters table
	$update_sth->execute($time_remaining_hours_formatted, $serial);

	# Log update with method
	log_info("Updated meter $serial with time_remaining_hours = "
		. (defined $time_remaining_hours_formatted ? $time_remaining_hours_formatted : 'NULL')
		. " using method: $method_used");}

log_info("All enabled meters updated successfully.");

# Disconnect from database
$dbh->disconnect;

# === UNLOCKING ===
# Clean up lock file after successful run
close($fh);
unlink $lockfile;
