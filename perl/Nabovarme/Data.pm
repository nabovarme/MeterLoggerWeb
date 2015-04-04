package Nabovarme::Data;

use strict;
use Apache2::Const;
use DBI;

use lib qw( /opt/local/apache2/perl/ );
use Nabovarme::Db;

sub handler {
	my $r = shift;
	my ($dbh, $sth, $d);
	
	my ($serial) = $r->uri =~ m|/(\d+)|;
	
	if ($dbh = Nabovarme::Db->my_connect) {
		my $quoted_serial = $dbh->quote($serial);
		$sth = $dbh->prepare(qq[SELECT \
			DATE_FORMAT(FROM_UNIXTIME(unix_time), "%Y/%m/%d %T") AS time_stamp_formatted, \
			serial, \
			flow_temp, \
			return_flow_temp, \
			temp_diff, \
			flow, \
			effect, \
			hours, \
			volume, \
			energy FROM samples WHERE `serial` LIKE ] . $quoted_serial . qq[ ORDER BY `unix_time` ASC]);
		$sth->execute;
	}
	
	if ($sth->rows) {
		$r->content_type('text/plain');
    	
		$r->print("Date,Temperature,Return temperature, Temperature diff.,Flow,Effect\n");
		while ($d = $sth->fetchrow_hashref) {
			$r->print($d->{time_stamp_formatted} . ',');
			$r->print($d->{flow_temp} . ',');
			$r->print($d->{return_flow_temp} . ',');
			$r->print($d->{temp_diff} . ',');
			$r->print($d->{flow} . ',');
			$r->print($d->{effect} . "\n");
		}
		
		return Apache2::Const::OK;
	}
	else {
		return Apache2::Const::NOT_FOUND;
	}
}

1;
