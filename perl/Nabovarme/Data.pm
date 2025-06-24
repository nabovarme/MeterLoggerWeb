package Nabovarme::Data;

use strict;
use Data::Dumper;
use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::Const;
use HTTP::Date qw(time2str);
use DBI;
use Fcntl qw(:flock);

use lib qw( /etc/apache2/perl );
use Nabovarme::Db;

sub handler {
	my $r = shift;
	my ($dbh, $sth, $d);

	# Get cache path from Apache config or default to '/cache'
	my $data_cache_path = $r->dir_config('DataCachePath') || '/cache';

	# Resolve full paths using Apache document root
	my $document_root = $r->document_root();

	# Parse URI into serial, option, and optional unix_time
	my ($serial, $option, $unix_time) = $r->uri =~ m|^/[^/]+/([^/]+)(?:/([^/]+))?(?:/([^/]+))?|;

	my $quoted_serial;
	my $setup_value = 0;

	# Connect to database using Nabovarme::Db
	if ($dbh = Nabovarme::Db->my_connect) {

		# Quote serial to prevent SQL injection
		$quoted_serial = $dbh->quote($serial);

		# --- Option: acc_coarse (daily energy, first sample of each day) ---
		if ($option =~ /acc_coarse/) {

			# Get setup_value for energy adjustment
			$sth = $dbh->prepare("SELECT setup_value FROM meters WHERE `serial` LIKE $quoted_serial LIMIT 1");
			$sth->execute;
			if ($d = $sth->fetchrow_hashref) {
				$setup_value = $d->{setup_value};
			}

			# Query daily first energy sample
			$sth = $dbh->prepare(qq[
				SELECT
					DATE_FORMAT(FROM_UNIXTIME(unix_time), "%Y/%m/%d %T") AS time_stamp_formatted,
					energy
				FROM samples_cache
				WHERE serial LIKE $quoted_serial
				AND is_spike != 1

				UNION ALL

				SELECT
					DATE_FORMAT(FROM_UNIXTIME(unix_time), "%Y/%m/%d %T") AS time_stamp_formatted,
					energy
				FROM samples_daily
				WHERE serial LIKE $quoted_serial
				  AND unix_time < UNIX_TIMESTAMP(NOW() - INTERVAL 7 DAY)

				ORDER BY time_stamp_formatted ASC;
			]);
			$sth->execute;

			$r->content_type('text/plain');
			$r->headers_out->set('Cache-Control'	=> 'public, max-age=60');
			$r->headers_out->set('Expires'			=> HTTP::Date::time2str(time + 60));

			$r->print("Date,Energy\n");
			while ($d = $sth->fetchrow_hashref) {
				$r->print("$d->{time_stamp_formatted}," . ($d->{energy} - $setup_value) . "\n");
			}
		}

		# --- Option: acc_fine (high-resolution energy, recent, with cache) ---
		elsif ($option =~ /acc_fine/) {

			$sth = $dbh->prepare("SELECT setup_value FROM meters WHERE `serial` LIKE $quoted_serial LIMIT 1");
			$sth->execute;
			if ($d = $sth->fetchrow_hashref) {
				$setup_value = $d->{setup_value};
			}

			my $cache_file = $document_root . $data_cache_path . '/' . $serial . '_acc.csv';

			if ((-e $cache_file) && ((time() - (stat($cache_file))[9]) < 3600)) {
				warn Dumper "Using cached acc_fine: $cache_file";
			} else {
				warn Dumper "Generating new acc_fine cache: $cache_file";

				$sth = $dbh->prepare(qq[
					SELECT
						DATE_FORMAT(FROM_UNIXTIME(unix_time), "%Y/%m/%d %T") AS time_stamp_formatted,
						energy
					FROM samples_hourly
					WHERE serial LIKE $quoted_serial
					  AND unix_time < UNIX_TIMESTAMP(NOW() - INTERVAL 7 DAY)
					ORDER BY unix_time ASC
				]);
				$sth->execute;

				open(my $fh, '>', $cache_file) or warn "Cannot open cache file $cache_file: $!";
				flock($fh, LOCK_EX) or return Apache2::Const::SERVER_ERROR;

				print $fh "Date,Energy\n";
				while ($d = $sth->fetchrow_hashref) {
					print $fh "$d->{time_stamp_formatted}," . ($d->{energy} - $setup_value) . "\n";
				}
				close($fh);
			}

			$r->internal_redirect('/' . $data_cache_path . '/' . $serial . '_acc.csv');
			return Apache2::Const::OK;
		}

		# --- Option: coarse (detailed daily sample) ---
		elsif ($option =~ /coarse/) {

			$sth = $dbh->prepare(qq[
				SELECT
					DATE_FORMAT(FROM_UNIXTIME(unix_time), "%Y/%m/%d %T") AS time_stamp_formatted,
					serial,
					flow_temp,
					return_flow_temp,
					temp_diff,
					flow,
					effect,
					hours,
					volume,
					energy
				FROM samples_cache
				WHERE serial LIKE $quoted_serial
				AND is_spike != 1

				UNION ALL

				SELECT
					DATE_FORMAT(FROM_UNIXTIME(unix_time), "%Y/%m/%d %T") AS time_stamp_formatted,
					serial,
					flow_temp,
					return_flow_temp,
					temp_diff,
					flow,
					effect,
					hours,
					volume,
					energy
				FROM samples_daily
				WHERE serial LIKE $quoted_serial
				  AND unix_time < UNIX_TIMESTAMP(NOW() - INTERVAL 7 DAY)

				ORDER BY time_stamp_formatted ASC;
			]);
			$sth->execute;

			$r->content_type('text/plain');
			$r->headers_out->set('Cache-Control'	=> 'public, max-age=60');
			$r->headers_out->set('Expires'			=> HTTP::Date::time2str(time + 60));

			$r->print("Date,Temperature,Return temperature,Temperature diff.,Flow,Effect\n");
			while ($d = $sth->fetchrow_hashref) {
				$r->print(join(',', 
					$d->{time_stamp_formatted},
					$d->{flow_temp},
					$d->{return_flow_temp},
					$d->{temp_diff},
					$d->{flow},
					$d->{effect}
				) . "\n");
			}
		}

		# --- Option: fine (high-resolution cached data, with cache) ---
		elsif ($option =~ /fine/) {

			my $cache_file = $document_root . $data_cache_path . '/' . $serial . '.csv';

			if ((-e $cache_file) && ((time() - (stat($cache_file))[9]) < 3600)) {
				warn Dumper "Cached version exists: $cache_file updated " . (time() - (stat($cache_file))[9]) . " seconds ago";
			} else {
				warn Dumper "No valid cache found: $cache_file - regenerating";

				$sth = $dbh->prepare(qq[
					SELECT
						DATE_FORMAT(FROM_UNIXTIME(unix_time), "%Y/%m/%d %T") AS time_stamp_formatted,
						serial,
						flow_temp,
						return_flow_temp,
						temp_diff,
						flow,
						effect,
						hours,
						volume,
						energy
					FROM samples_hourly
					WHERE serial = $quoted_serial
					  AND unix_time < UNIX_TIMESTAMP(NOW() - INTERVAL 7 DAY)
					ORDER BY unix_time ASC
				]);
				$sth->execute;

				open(my $fh, '>', $cache_file) or warn "Cannot open cache file $cache_file: $!";
				flock($fh, LOCK_EX) or return Apache2::Const::SERVER_ERROR;

				print $fh "Date,Temperature,Return temperature,Temperature diff.,Flow,Effect\n";
				while ($d = $sth->fetchrow_hashref) {
					print $fh join(',', 
						$d->{time_stamp_formatted},
						$d->{flow_temp},
						$d->{return_flow_temp},
						$d->{temp_diff},
						$d->{flow},
						$d->{effect}
					) . "\n";
				}
				close($fh);
			}

			$r->internal_redirect('/' . $data_cache_path . '/' . $serial . '.csv');
			return Apache2::Const::OK;
		}

		# --- Option: all (high-resolution raw unfiltered data) ---
		elsif ($option =~ /all/) {
			$sth = $dbh->prepare(qq[
				SELECT
					DATE_FORMAT(FROM_UNIXTIME(unix_time), "%Y/%m/%d %T") AS time_stamp_formatted,
					serial,
					flow_temp,
					return_flow_temp,
					temp_diff,
					flow,
					effect,
					hours,
					volume,
					energy
				FROM samples
				WHERE serial = $quoted_serial
				ORDER BY unix_time ASC
			]);
			$sth->execute;

			$r->content_type('text/plain');
			$r->headers_out->set('Cache-Control'	=> 'public, max-age=60');
			$r->headers_out->set('Expires'			=> HTTP::Date::time2str(time + 60));

			$r->print("Date,Temperature,Return temperature,Temperature diff.,Flow,Effect\n");
			while ($d = $sth->fetchrow_hashref) {
				$r->print(join(',', 
					$d->{time_stamp_formatted},
					$d->{flow_temp},
					$d->{return_flow_temp},
					$d->{temp_diff},
					$d->{flow},
					$d->{effect}
				) . "\n");
			}
		}

		# --- Unknown option: return 404 ---
		else {
			return Apache2::Const::NOT_FOUND;
		}

		return Apache2::Const::OK;
	}
	else {
		$r->status(Apache2::Const::SERVER_ERROR);
		$r->content_type('text/plain');
		$r->print("Database connection failed.\n");
		return Apache2::Const::OK;
	}
}

1;

__END__
