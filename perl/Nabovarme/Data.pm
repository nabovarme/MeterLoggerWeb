package Nabovarme::Data;

use strict;
use Data::Dumper;
use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::Const;
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

			$r->content_type('text/plain');
			$r->print("Date,Energy\n");

			# Query daily first energy sample
			$sth = $dbh->prepare(qq[
				SELECT 
					DATE_FORMAT(FROM_UNIXTIME(sc.unix_time), "%Y/%m/%d %T") AS time_stamp_formatted,
					energy
				FROM samples_calculated sc
				JOIN (
					SELECT FROM_UNIXTIME(unix_time, '%Y-%m-%d') AS day,
						   MIN(unix_time) AS min_time
					FROM samples_calculated
					WHERE serial = $quoted_serial
					GROUP BY day
				) first_per_day
				  ON FROM_UNIXTIME(sc.unix_time, '%Y-%m-%d') = first_per_day.day
				 AND sc.unix_time = first_per_day.min_time
				WHERE sc.serial = $quoted_serial
				ORDER BY sc.unix_time ASC
			]);
			$sth->execute;

			while ($d = $sth->fetchrow_hashref) {
				$r->print("$d->{time_stamp_formatted}," . ($d->{energy} - $setup_value) . "\n");
			}
		}

		# --- Option: acc_fine (high-resolution energy, recent) ---
		elsif ($option =~ /acc_fine/) {

			$sth = $dbh->prepare("SELECT setup_value FROM meters WHERE `serial` LIKE $quoted_serial LIMIT 1");
			$sth->execute;
			if ($d = $sth->fetchrow_hashref) {
				$setup_value = $d->{setup_value};
			}

			$r->content_type('text/plain');
			$r->print("Date,Energy\n");

			$sth = $dbh->prepare(qq[
				SELECT
					DATE_FORMAT(FROM_UNIXTIME(unix_time), "%Y/%m/%d %T") AS time_stamp_formatted,
					energy
				FROM samples_cache
				WHERE serial LIKE $quoted_serial
				ORDER BY unix_time ASC
			]);
			$sth->execute;

			while ($d = $sth->fetchrow_hashref) {
				$r->print("$d->{time_stamp_formatted}," . ($d->{energy} - $setup_value) . "\n");
			}
		}

		# --- Option: coarse (detailed daily sample) ---
		elsif ($option =~ /coarse/) {

			$r->content_type('text/plain');

			$sth = $dbh->prepare(qq[
				SELECT
					DATE_FORMAT(FROM_UNIXTIME(sc.unix_time), "%Y/%m/%d %T") AS time_stamp_formatted,
					sc.serial,
					sc.flow_temp,
					sc.return_flow_temp,
					sc.temp_diff,
					sc.flow,
					sc.effect,
					sc.hours,
					sc.volume,
					sc.energy
				FROM samples_calculated sc
				JOIN (
					SELECT
						FROM_UNIXTIME(unix_time, '%Y-%m-%d') AS day,
						MIN(unix_time) AS min_time
					FROM samples_calculated
					WHERE serial = $quoted_serial
					GROUP BY day
				) first_per_day
				  ON FROM_UNIXTIME(sc.unix_time, '%Y-%m-%d') = first_per_day.day
				 AND sc.unix_time = first_per_day.min_time
				WHERE sc.serial = $quoted_serial
				ORDER BY sc.unix_time ASC
			]);
			$sth->execute;

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

		# --- Option: fine (high-resolution cached data) ---
		elsif ($option =~ /fine/) {

			my $cache_file = $document_root . $data_cache_path . '/' . $serial . '.csv';

			if ((-e $cache_file) && ((time() - (stat($cache_file))[9]) < 3600)) {
				warn Dumper "Cached version exists: $cache_file updated " . (time() - (stat($cache_file))[9]) . " seconds ago";
			}
			else {
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
					FROM samples_cache
					WHERE serial = $quoted_serial
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

		# --- Unknown option: return 404 ---
		else {
			return Apache2::Const::NOT_FOUND;
		}

		return Apache2::Const::OK;
	}
}

1;

__END__
