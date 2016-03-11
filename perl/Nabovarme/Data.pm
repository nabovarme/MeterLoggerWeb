package Nabovarme::Data;

use strict;
use Data::Dumper;
use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::Const;
use DBI;

use lib qw( /var/www/perl/lib );
#use lib qw( /opt/local/apache2/perl );
use Nabovarme::Db;

sub handler {
	my $r = shift;
	my ($dbh, $sth, $sth2, $d, $d2);
	
	my ($serial, $option) = $r->uri =~ m|/(\d+)(?:/([^/]+))?|;
	my $quoted_serial;
	my $last_energy = 0;
	
	my $csv_header_set = 0;
	
	if ($dbh = Nabovarme::Db->my_connect) {
		$quoted_serial = $dbh->quote($serial);
		
		if ($option =~ /acc/) {		# accumulated energy
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
			$sth->execute;	
		
			$sth2 = $dbh->prepare(qq[SELECT last_energy FROM meters WHERE `serial` LIKE ] . $quoted_serial . qq[ LIMIT 1]);
			$sth2->execute;
			if ($d2 = $sth2->fetchrow_hashref) {
				$last_energy = $d2->{last_energy};
			}
			$r->print("Date,Energy\n");
			while ($d = $sth->fetchrow_hashref) {
				$r->print($d->{time_stamp_formatted} . ',');
				$r->print(($d->{energy} - $last_energy) . "\n");
			}			
		}
		else {		# detailed data
			if ($option =~ /high/) {
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
					energy FROM samples WHERE `serial` LIKE AND effect IS NOT NULL] . $quoted_serial . qq[ ORDER BY `unix_time` ASC]);
			}
			else {
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
					AND FROM_UNIXTIME(`unix_time`) < NOW() - INTERVAL 7 DAY \
					AND effect IS NOT NULL \
					GROUP BY DATE( FROM_UNIXTIME(`unix_time`) ), HOUR( FROM_UNIXTIME(`unix_time`) ) \
					ORDER BY FROM_UNIXTIME(`unix_time`) ASC]);
			}
			$sth->execute;
			if ($sth->rows) {
				$r->content_type('text/plain');
    	
				$r->print("Date,Temperature,Return temperature, Temperature diff.,Flow,Effect\n");
				$csv_header_set = 1;
				while ($d = $sth->fetchrow_hashref) {
					$r->print($d->{time_stamp_formatted} . ',');
					$r->print($d->{flow_temp} . ',');
					$r->print($d->{return_flow_temp} . ',');
					$r->print($d->{temp_diff} . ',');
					$r->print($d->{flow} . ',');
					$r->print($d->{effect} . "\n");
				}
			}
	
			# get highres data
			unless ($option =~ /high/) {
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
					energy FROM samples WHERE `serial` LIKE ] . $quoted_serial . qq[ \
				    AND FROM_UNIXTIME(`unix_time`) >= NOW() - INTERVAL 7 DAY \
					AND effect IS NOT NULL \
					ORDER BY `unix_time` ASC]);
				$sth->execute;
				if ($sth->rows) {
					unless ($csv_header_set) {
						$r->print("Date,Temperature,Return temperature, Temperature diff.,Flow,Effect\n");
					}
					while ($d = $sth->fetchrow_hashref) {
						$r->print($d->{time_stamp_formatted} . ',');
						$r->print($d->{flow_temp} . ',');
						$r->print($d->{return_flow_temp} . ',');
						$r->print($d->{temp_diff} . ',');
						$r->print($d->{flow} . ',');
						$r->print($d->{effect} . "\n");
					}
				}
			}
		}
	
		if ($sth->rows) {
			return Apache2::Const::OK;
		}
		else {
			return Apache2::Const::NOT_FOUND;	
		}	
	}	
}

1;

__END__
