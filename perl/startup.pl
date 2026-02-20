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
use Nabovarme::APIWiFiPending;
use Nabovarme::APIWiFiScan;
use Nabovarme::APISMSSent;

1;
