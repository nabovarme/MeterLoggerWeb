use strict;
use warnings;

# List of required environment variables
my @required_env = qw(
	METERLOGGER_DB_HOST
	METERLOGGER_DB_USER
	METERLOGGER_DB_PASSWORD
);

my @missing;
foreach my $var (@required_env) {
	push @missing, $var unless exists $ENV{$var} && length $ENV{$var};
}

if (@missing) {
	die "Missing required environment variables: " . join(", ", @missing) . "\n";
}

# --- now load the rest of your modules ---
use lib qw(/etc/apache2/perl);

use Embperl;
use Data::Dumper;
use DBI;
use Nabovarme::Data;
use Nabovarme::QR;
use Nabovarme::NetworkData;
use Nabovarme::Redirect;
use Nabovarme::SMSAuth;
use Nabovarme::APIDataAcc;
use Nabovarme::APIMeters;
use Nabovarme::APIMetersNetworkTree;
use Nabovarme::APIAlarms;
use Nabovarme::APISnooze;
use Nabovarme::APIPaymentsPending;
use Nabovarme::APIAccount;
use Nabovarme::APIWIFIPending;
use Nabovarme::APISMSSent;

1;
