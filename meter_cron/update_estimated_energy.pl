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

	# override for NO_AUTO_CLOSE meters
	my $sth_sw = $dbh->prepare("SELECT sw_version FROM meters WHERE serial = ?");
	$sth_sw->execute($serial);
	my ($sw_version) = $sth_sw->fetchrow_array;
	if ($sw_version && $sw_version =~ /NO_AUTO_CLOSE/) {
		$time_remaining_hours = undef;
	}

	my $time_remaining_hours_formatted = defined $time_remaining_hours ? sprintf("%.2f", $time_remaining_hours) : undef;

	# Update meters table
	$update_sth->execute($time_remaining_hours_formatted, $serial);

	# Log update
	print "Updated meter $serial with time_remaining_hours = " . (defined $time_remaining_hours_formatted ? $time_remaining_hours_formatted : 'NULL') . "\n";
}

print "All enabled meters updated successfully.\n";

# Disconnect from database
$dbh->disconnect;
