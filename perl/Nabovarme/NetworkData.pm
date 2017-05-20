package Nabovarme::NetworkData;

use strict;
use Data::Dumper;
use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::Const;
use DBI;
#use utf8;

use lib qw( /etc/apache2/perl );
#use lib qw( /opt/local/apache2/perl );
use Nabovarme::Db;

sub handler {
	my $r = shift;
	my ($dbh, $sth, $sth_last_energy, $d);
	my $count = 0;
	
	if ($dbh = Nabovarme::Db->my_connect) {
		$sth = $dbh->prepare(qq[SELECT `serial`, `info`, trim(trailing char(0) from `ssid`) as `ssid`, `rssi`, `last_updated`, trim(trailing char(0) from `sw_version`) as `sw_version` FROM meters ORDER BY `ssid` asc, `rssi` desc]);
		$sth->execute;
		$count = $sth->rows;
		if ($count) {
			$r->print("[");
			while ($d = $sth->fetchrow_hashref) {
				$r->print('['); 
				$r->print('"' . $d->{serial} . '"' . ',');
				$r->print('"' . $d->{info} . '"' . ',');
				$r->print('"' . $d->{ssid} . '"' . ',');
				$r->print('"mesh-' . $d->{serial} . '"' . ',');
				$r->print('"' . $d->{rssi} . '"' . ',');
				$r->print('"' . $d->{last_updated} . '"' . ',');
				$r->print('"' . $d->{sw_version} . '"');
				
				$count--;
				if ($count) {
        				$r->print("],");
                                }
                                else {
                                        $r->print("]");
                                }	
			}
			$r->print("]");
		}
	}

	if ($sth->rows) {
	        $r->content_type("application/json; charset=iso-8859-1");
	        $r->err_headers_out->add("Access-Control-Allow-Origin" => '*');
		return Apache2::Const::OK;
	}
	else {
		return Apache2::Const::NOT_FOUND;	
	}	
}

1;

__END__
