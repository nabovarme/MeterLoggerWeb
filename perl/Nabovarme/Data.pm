package Nabovarme::Data;

use strict;
use Data::Dumper;
use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::Const;
use DBI;

#use lib qw( /var/www/lib/perl );
use lib qw( /opt/local/apache2/perl );
use Nabovarme::Db;

sub handler {
	my $r = shift;
	my ($dbh, $sth, $d);
	
	my ($serial, $resolution) = $r->uri =~ m|/(\d+)(?:/(\d+))?|;
	warn Dumper ($serial, $resolution);
	
	if ($dbh = Nabovarme::Db->my_connect) {
		my $quoted_serial = $dbh->quote($serial);
		if ($resolution) {
			$sth = $dbh->prepare(qq[SELECT \
				DATE_FORMAT(FROM_UNIXTIME(unix_time), "%Y/%m/%d %T") AS `time_stamp_formatted`, \
				serial, \
				AVG(`flow_temp`) as `flow_temp`, \
				AVG(`return_flow_temp`) as `return_flow_temp`, \
				AVG(`temp_diff`) as `temp_diff`, \
				AVG(`flow`) as `flow`, \
				AVG(`effect`) as `effect`, \
				`hours`, \
				`volume`, \
				`energy` \
				FROM `samples` \
				WHERE `serial` LIKE ] . $quoted_serial . qq[ \
				GROUP BY DATE( FROM_UNIXTIME(`unix_time`) ), HOUR( FROM_UNIXTIME(`unix_time`) ) \
				ORDER BY FROM_UNIXTIME(`unix_time`) ASC]);
		}
		else {
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
		}
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

__END__
