package Nabovarme::Data;

use strict;
use Data::Dumper;
use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::Const;
use DBI;

use lib qw( /etc/apache2/perl );
#use lib qw( /opt/local/apache2/perl );
use Nabovarme::Db;

sub handler {
	my $r = shift;
	my ($dbh, $sth, $sth2, $d, $d2);
	
	my $data_cache_path = $r->dir_config('DataCachePath') || '/cache';
	my $document_root = $r->document_root();

#	my ($serial, $option, $unix_time) = $r->uri =~ m|/([^/]+)(?:/([^/]+))?$|;
	my ($serial, $option, $unix_time) = $r->uri =~ m|^/[^/]+/([^/]+)(?:/([^/]+))?(?:/([^/]+))?|;
#	warn Dumper {uri => $r->uri, serial => $serial, option => $option, unix_time => $unix_time};
	my $quoted_serial;
	my $setup_value = 0;
	
	my $csv_header_set = 0;
	
	if ($dbh = Nabovarme::Db->my_connect) {
		$quoted_serial = $dbh->quote($serial);
		
		if ($option =~ /effect/) {		# effect
			$sth = $dbh->prepare(qq[SELECT \
				DATE_FORMAT(FROM_UNIXTIME(unix_time), "%Y/%m/%d %T") AS `time_stamp_formatted`, \
				`effect` \
				FROM `samples_calculated` \
				WHERE `serial` LIKE ] . $quoted_serial . qq[ \
				ORDER BY `unix_time` ASC]);
			$sth->execute;	
		
			$r->content_type('text/plain');
			$r->print("Date,Effect\n");
			while ($d = $sth->fetchrow_hashref) {
				$r->print($d->{time_stamp_formatted} . ',');
				$r->print(($d->{effect}) . "\n");
			}
			# get last
			$sth = $dbh->prepare(qq[SELECT \
				DATE_FORMAT(FROM_UNIXTIME(unix_time), "%Y/%m/%d %T") AS time_stamp_formatted, \
				effect FROM samples WHERE `serial` LIKE ] . $quoted_serial . qq[ \
				ORDER BY `unix_time` ASC LIMIT 1]);
			$sth->execute;
			if ($sth->rows) {
				while ($d = $sth->fetchrow_hashref) {
					$r->print($d->{time_stamp_formatted} . ',');
					$r->print(($d->{effect}) . "\n");
				}
			}

		}
		elsif ($option =~ /volume_acc/) {		# accumulated energy
			$sth = $dbh->prepare(qq[SELECT \
				DATE_FORMAT(FROM_UNIXTIME(unix_time), "%Y/%m/%d %T") AS `time_stamp_formatted`, \
				`volume` \
				FROM `samples_calculated` \
				WHERE `serial` LIKE ] . $quoted_serial . qq[ \
				AND FROM_UNIXTIME(`unix_time`) < NOW() - INTERVAL 7 DAY \
				ORDER BY `unix_time` ASC]);
			$sth->execute;	
		
			$sth2 = $dbh->prepare(qq[SELECT setup_value FROM meters WHERE `serial` LIKE ] . $quoted_serial . qq[ LIMIT 1]);
			$sth2->execute;
			if ($d2 = $sth2->fetchrow_hashref) {
				$setup_value = $d2->{setup_value};
			}
			$r->content_type('text/plain');
			$r->print("Date,Volume\n");
			$csv_header_set = 1;
			while ($d = $sth->fetchrow_hashref) {
				$r->print($d->{time_stamp_formatted} . ',');
				$r->print(($d->{volume} - $setup_value) . "\n");
			}

			# get highres data
			$sth = $dbh->prepare(qq[SELECT \
				DATE_FORMAT(FROM_UNIXTIME(unix_time), "%Y/%m/%d %T") AS time_stamp_formatted, \
				volume FROM samples_cache WHERE `serial` LIKE ] . $quoted_serial . qq[ \
			    AND FROM_UNIXTIME(`unix_time`) >= NOW() - INTERVAL 7 DAY \
				ORDER BY `unix_time` ASC]);
			$sth->execute;
			if ($sth->rows) {
				unless ($csv_header_set) {
					$r->print("Date,Volume\n");
				}
				while ($d = $sth->fetchrow_hashref) {
					$r->print($d->{time_stamp_formatted} . ',');
					$r->print(($d->{volume} - $setup_value) . "\n");
				}
			}
		}
		elsif ($option =~ /acc/) {		# accumulated energy
			$sth = $dbh->prepare(qq[SELECT \
				DATE_FORMAT(FROM_UNIXTIME(unix_time), "%Y/%m/%d %T") AS `time_stamp_formatted`, \
				`energy` \
				FROM `samples_calculated` \
				WHERE `serial` LIKE ] . $quoted_serial . qq[ \
				AND FROM_UNIXTIME(`unix_time`) < NOW() - INTERVAL 7 DAY \
				ORDER BY `unix_time` ASC]);
			$sth->execute;	
		
			$sth2 = $dbh->prepare(qq[SELECT setup_value FROM meters WHERE `serial` LIKE ] . $quoted_serial . qq[ LIMIT 1]);
			$sth2->execute;
			if ($d2 = $sth2->fetchrow_hashref) {
				$setup_value = $d2->{setup_value};
			}
			$r->content_type('text/plain');
			$r->print("Date,Energy\n");
			$csv_header_set = 1;
			while ($d = $sth->fetchrow_hashref) {
				$r->print($d->{time_stamp_formatted} . ',');
				$r->print(($d->{energy} - $setup_value) . "\n");
			}

			# get highres data
			$sth = $dbh->prepare(qq[SELECT \
				DATE_FORMAT(FROM_UNIXTIME(unix_time), "%Y/%m/%d %T") AS time_stamp_formatted, \
				energy FROM `samples_cache` WHERE `serial` LIKE ] . $quoted_serial . qq[ \
			    AND FROM_UNIXTIME(`unix_time`) >= NOW() - INTERVAL 7 DAY \
				ORDER BY `unix_time` ASC]);
			$sth->execute;
			if ($sth->rows) {
				unless ($csv_header_set) {
					$r->print("Date,Temperature,Return temperature,Temperature diff.,Flow,Effect\n");
				}
				while ($d = $sth->fetchrow_hashref) {
					$r->print($d->{time_stamp_formatted} . ',');
					$r->print(($d->{energy} - $setup_value) . "\n");
				}
			}
		}
		elsif ($option =~ /last/) {		# last accumulated
		        if ($unix_time) {
			        $sth = $dbh->prepare(qq[SELECT \
				        DATE_FORMAT(FROM_UNIXTIME(unix_time), "%Y/%m/%d %T") AS time_stamp_formatted, \
        				energy FROM `samples` WHERE `serial` LIKE ] . $quoted_serial . qq[ \
        				AND `unix_time` <= ] . $dbh->quote($unix_time) . qq[ \
        				ORDER BY `unix_time` DESC \
        				LIMIT 1]);
                        }
                        else {
			        $sth = $dbh->prepare(qq[SELECT \
				        DATE_FORMAT(FROM_UNIXTIME(unix_time), "%Y/%m/%d %T") AS time_stamp_formatted, \
        				energy FROM `samples_cache` WHERE `serial` LIKE ] . $quoted_serial . qq[ \
        				ORDER BY `unix_time` DESC \
        				LIMIT 1]);                        
                        }
			$sth->execute;
			if ($sth->rows) {
				unless ($csv_header_set) {
				        $r->print("Date,Energy\n");
				}
				while ($d = $sth->fetchrow_hashref) {
					$r->print($d->{time_stamp_formatted} . ',');
					$r->print(($d->{energy} - $setup_value) . "\n");
				}
			}
		}
		elsif ($option =~ /new_range/) {		# new range looked up from db
			$r->content_type('text/plain');
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
				energy FROM `samples_cache` WHERE `serial` LIKE ] . $quoted_serial . qq[ \
			    AND FROM_UNIXTIME(`unix_time`) >= NOW() - INTERVAL 7 DAY \
				ORDER BY `unix_time` ASC]);
			$sth->execute;
			if ($sth->rows) {
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
		elsif ($option =~ /old_range/) {		# old range cached from disk
			if ( (-e $document_root . $data_cache_path . '/' . $serial . '.csv') && 
				 ((time() - (stat($document_root . $data_cache_path . '/' . $serial . '.csv'))[9] < 3600)) ) {
				warn Dumper "cached version exists: " . $document_root . $data_cache_path . '/' . $serial . '.csv' . " changed " . (time() - (stat($document_root . $data_cache_path . '/' . $serial . '.csv'))[9]) . " seconds ago";
			}
			else {
				warn Dumper "no valid cache found: " . $document_root . $data_cache_path . '/' . $serial . '.csv' . " we need to create it";
				
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
					energy FROM `samples_calculated` WHERE `serial` LIKE ] . $quoted_serial . qq[ \
					AND FROM_UNIXTIME(`unix_time`) < NOW() - INTERVAL 7 DAY \
					ORDER BY `unix_time` ASC]);
				$sth->execute;
				open(my $fh, '>', $document_root . $data_cache_path . '/' . $serial . '.csv') || warn $!;
				if ($sth->rows) {
					open(my $fh, '>', $document_root . $data_cache_path . '/' . $serial . '.csv') || warn $!;
					print($fh "Date,Temperature,Return temperature,Temperature diff.,Flow,Effect\n");
					while ($d = $sth->fetchrow_hashref) {
						print($fh $d->{time_stamp_formatted} . ',');
						print($fh $d->{flow_temp} . ',');
						print($fh $d->{return_flow_temp} . ',');
						print($fh $d->{temp_diff} . ',');
						print($fh $d->{flow} . ',');
						print($fh $d->{effect} . "\n");
					}
				}
				close($fh);
			}
			#$r->content_type('text/plain');
			#$r->print("Date,Temperature,Return temperature,Temperature diff.,Flow,Effect\n");
			$r->internal_redirect('/' . $data_cache_path . '/' . $serial . '.csv');
			return Apache2::Const::OK;
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
					energy FROM `samples` WHERE `serial` LIKE ] . $quoted_serial . qq[ ORDER BY `unix_time` ASC]);
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
					energy FROM `samples_calculated` WHERE `serial` LIKE ] . $quoted_serial . qq[ \
					AND FROM_UNIXTIME(`unix_time`) < NOW() - INTERVAL 7 DAY \
					ORDER BY `unix_time` ASC]);
			}
			$sth->execute;
			if ($sth->rows) {
				$r->content_type('text/plain');
    	
				$r->print("Date,Temperature,Return temperature,Temperature diff.,Flow,Effect\n");
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
					energy FROM `samples_cache` WHERE `serial` LIKE ] . $quoted_serial . qq[ \
				    AND FROM_UNIXTIME(`unix_time`) >= NOW() - INTERVAL 7 DAY \
					ORDER BY `unix_time` ASC]);
				$sth->execute;
				if ($sth->rows) {
					unless ($csv_header_set) {
						$r->print("Date,Temperature,Return temperature,Temperature diff.,Flow,Effect\n");
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
	
#		if ($sth->rows) {
			return Apache2::Const::OK;
#		}
#		else {
#			return Apache2::Const::NOT_FOUND;	
#		}	
	}	
}

1;

__END__
