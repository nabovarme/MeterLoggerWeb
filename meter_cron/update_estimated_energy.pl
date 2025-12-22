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

# Prepare update statement for estimated_energy (kW)
my $update_sth = $dbh->prepare("UPDATE meters SET estimated_energy = ? WHERE serial = ?");

# Fetch all enabled meters
my $sth = $dbh->prepare("SELECT serial FROM meters WHERE enabled = 1");
$sth->execute();

while (my ($serial) = $sth->fetchrow_array) {

    # Calculate remaining energy using Nabovarme::Utils
    my $est = Nabovarme::Utils::estimate_remaining_energy($dbh, $serial);

    # Extract average energy per hour (kWh/h) → represents power in kW
    my $kW = $est->{avg_energy_last_day} || 0;

    # Update meters table
    $update_sth->execute($kW, $serial);

    # Log update
    print "Updated meter $serial with estimated power = $kW kW\n";
}

# All meters updated
print "All enabled meters updated successfully.\n";

# Disconnect from database
$dbh->disconnect;
