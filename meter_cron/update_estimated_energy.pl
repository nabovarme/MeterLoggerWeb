#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;

use lib qw( /etc/apache2/perl );
use Nabovarme::Db;
use Nabovarme::Utils;

# Connect to database
my $dbh = Nabovarme::Db->my_connect;
die "DB connection failed" unless $dbh;

# Prepare update statement for time_remaining_hours_string and time_remaining_hours
my $update_sth = $dbh->prepare(
	"UPDATE meters SET time_remaining_hours = ?, time_remaining_hours_string = ? WHERE serial = ?"
);

# Fetch all enabled meters
my $sth = $dbh->prepare(
	"SELECT serial FROM meters WHERE enabled = 1"
);
$sth->execute();

while (my ($serial) = $sth->fetchrow_array) {

	# Calculate remaining values using Utils
	my $est = Nabovarme::Utils::estimate_remaining_energy($dbh, $serial);

	my $time_remaining_hours = defined $est->{time_remaining_hours} ? sprintf("%.2f", $est->{time_remaining_hours}) : undef;
	my $time_remaining_hours_string = $est->{time_remaining_hours_string} || '∞';

	# Update meters table
	$update_sth->execute($time_remaining_hours, $time_remaining_hours_string, $serial);

	# Log update
	print "Updated meter $serial with time_remaining_hours = " . (defined $time_remaining_hours ? $time_remaining_hours : 'NULL') .
		  ", time_remaining_hours_string = $time_remaining_hours_string\n";
}

print "All enabled meters updated successfully.\n";

# Disconnect from database
$dbh->disconnect;
