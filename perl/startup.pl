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
use Nabovarme::APIMetersTree;
use Nabovarme::APIAlarms;
use Nabovarme::APIPaymentsPending;

1;
