#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
use FindBin;

use lib qw( /etc/apache2/perl );
use Nabovarme::Db;
use Nabovarme::Utils;

# Connect to database
my $dbh = Nabovarme::Db->my_connect;
die "DB connection failed" unless $dbh;

# Prepare update statement for time_remaining_hours_string
my $update_sth = $dbh->prepare(
	"UPDATE meters SET time_remaining_hours_string = ? WHERE serial = ?"
);

# Fetch all enabled meters
my $sth = $dbh->prepare(
	"SELECT serial FROM meters WHERE enabled = 1"
);
$sth->execute();

while (my ($serial) = $sth->fetchrow_array) {

	# Calculate remaining values using Utils
	my $est = Nabovarme::Utils::estimate_remaining_energy($dbh, $serial);

	# Extract formatted remaining time string
	my $time_remaining_hours_string = $est->{time_remaining_hours_string} || 'NULL';

	# Update meters table
	$update_sth->execute($time_remaining_hours_string, $serial);

	# Log update
	print "Updated meter $serial with time_remaining_hours_string = $time_remaining_hours_string\n";
}

print "All enabled meters updated successfully.\n";

# Disconnect from database
$dbh->disconnect;
