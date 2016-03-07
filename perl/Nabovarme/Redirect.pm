package Nabovarme::Redirect;

use strict;
use Data::Dumper;
use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::Const -compile => qw(OK DONE REDIRECT NOT_FOUND);
use DBI;

use lib qw( /var/www/perl/lib );
#use lib qw( /opt/local/apache2/perl );
use Nabovarme::Db;

sub handler {
	my $r = shift;
	my ($dbh, $sth, $d);
	
	if ($r->uri =~ m|^/nabovarme/data/|) {
		return Apache2::Const::OK;	# not handled	
	}
	
	if ($r->uri =~ m|^/nabovarme/.*\.epl|) {
		return Apache2::Const::OK;	# not handled here
	}

	# handle /nabovarme/ -> /nabovarme/index.epl
	if ($r->uri =~ m|^/nabovarme/$|) {
		$r->headers_out->set('Location' => "/nabovarme/index.epl");
		return Apache2::Const::REDIRECT;
	}
	
	# handle short url
	my ($meter_info) = $r->uri =~ m|^/nabovarme/([^/]+)/?$|;
	my $quoted_meter_info;
	
	if ($meter_info =~ /^\d+$/) {
		$r->headers_out->set('Location' => "/nabovarme/detail_acc.epl?serial=$meter_info");
		return Apache2::Const::REDIRECT;
	}
	else {
		warn Dumper({meter_info => $meter_info});
		if ($meter_info && ($dbh = Nabovarme::Db->my_connect)) {
			$meter_info = "%" . $meter_info . "%";
			$quoted_meter_info = $dbh->quote($meter_info);

			warn Dumper(qq[SELECT `serial` FROM meters WHERE info like $quoted_meter_info limit 1]);
			$sth = $dbh->prepare(qq[SELECT `serial` FROM meters WHERE info like $quoted_meter_info limit 1]);
			$sth->execute;
			if ($d = $sth->fetchrow_hashref) {
				warn Dumper({looked_up_serial => $d->{serial}});
				$r->headers_out->set('Location' => "/nabovarme/detail_acc.epl?serial=" . $d->{serial});
				return Apache2::Const::REDIRECT;
			}
		}
		#else {
		#	# db connect error
		#	return Apache2::Const::NOT_FOUND;
		#}
	}
	return Apache2::Const::OK;	# not handled	
}

1;

__END__
