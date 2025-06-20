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

	# Read Apache configuration for the data cache directory, default to '/cache' if not set
	my $data_cache_path = $r->dir_config('DataCachePath') || '/cache';

	# Get the document root directory to resolve absolute paths for cache files
	my $document_root = $r->document_root();

	# Parse URI to extract the serial number, option, and optional unix_time
	# Example URI: /app/serial/option/unix_time
	my ($serial, $option, $unix_time) = $r->uri =~ m|^/[^/]+/([^/]+)(?:/([^/]+))?(?:/([^/]+))?|;

	my $quoted_serial;
	my $setup_value = 0;

	# Establish a database connection using custom Nabovarme::Db module
	if ($dbh = Nabovarme::Db->my_connect) {

		# Safely quote the serial number for SQL queries to avoid injection risks
		$quoted_serial = $dbh->quote($serial);

		# Dispatch based on the requested option from the URI
		if ($option =~ /acc_coarse/) {
			# Provide accumulated energy data with coarse granularity (daily first samples)

			# Fetch meter's setup_value to adjust energy readings
			$sth = $dbh->prepare(qq[SELECT setup_value FROM meters WHERE `serial` LIKE ] . $quoted_serial . qq[ LIMIT 1]);
			$sth->execute;
			if ($d = $sth->fetchrow_hashref) {
				$setup_value = $d->{setup_value};
			}

			# Set response content-type to plain text CSV
			$r->content_type('text/plain');
			$r->print("Date,Energy\n");

			# Query for the earliest sample per day to get daily coarse data
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

			# Output adjusted energy (energy minus setup_value) per day
			if ($sth->rows) {
				while ($d = $sth->fetchrow_hashref) {
					$r->print($d->{time_stamp_formatted} . ',');
					$r->print(($d->{energy} - $setup_value) . "\n");
				}
			}
		}
		elsif ($option =~ /acc_fine/) {
			# Provide accumulated energy data with fine granularity (last 7 days)

			# Retrieve setup_value for adjustments
			$sth = $dbh->prepare(qq[SELECT setup_value FROM meters WHERE `serial` LIKE ] . $quoted_serial . qq[ LIMIT 1]);
			$sth->execute;
			if ($d = $sth->fetchrow_hashref) {
				$setup_value = $d->{setup_value};
			}

			# Set response content-type to CSV
			$r->content_type('text/plain');
			$r->print("Date,Energy\n");

			# Query fine-grained samples from last 7 days
			$sth = $dbh->prepare(qq[
				SELECT
					DATE_FORMAT(FROM_UNIXTIME(unix_time), "%Y/%m/%d %T") AS time_stamp_formatted,
					energy
				FROM samples_cache
				WHERE serial LIKE $quoted_serial
				AND FROM_UNIXTIME(unix_time) >= NOW() - INTERVAL 7 DAY
				ORDER BY unix_time ASC
			]);
			$sth->execute;

			# Output adjusted energy values
			if ($sth->rows) {
				while ($d = $sth->fetchrow_hashref) {
					$r->print($d->{time_stamp_formatted} . ',');
					$r->print(($d->{energy} - $setup_value) . "\n");
				}
			}
		}
		elsif ($option =~ /coarse/) {
			# Provide coarse-grained detailed sample data (first sample per day)

			$r->content_type('text/plain');

			# Query first sample per day with multiple detailed fields
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

			# Print CSV header line for coarse data
			$r->print("Date,Temperature,Return temperature,Temperature diff.,Flow,Effect\n");

			# Print each sample row
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
		elsif ($option =~ /fine/) {
			# Provide fine-grained detailed sample data using caching for performance

			# Check if cache file exists and is recent (within last hour)
			my $cache_file = $document_root . $data_cache_path . '/' . $serial . '.csv';
			if ( (-e $cache_file) && ((time() - (stat($cache_file))[9]) < 3600) ) {
				# Cache is valid; log a debug message and skip regeneration
				warn Dumper "Cached version exists: $cache_file changed " . (time() - (stat($cache_file))[9]) . " seconds ago";
			}
			else {
				# Cache missing or outdated; generate fresh CSV cache

				warn Dumper "No valid cache found: $cache_file - regenerating";

				# Query recent sample data from last 7 days
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
					AND unix_time >= UNIX_TIMESTAMP(NOW() - INTERVAL 7 DAY)
					ORDER BY unix_time ASC
				]);
				$sth->execute;

				# Open the cache file with exclusive lock to prevent race conditions
				open(my $fh, '>', $cache_file) or warn "Cannot open cache file $cache_file: $!";
				flock($fh, LOCK_EX) or return Apache2::Const::SERVER_ERROR;

				# Write CSV header for detailed sample data
				print $fh "Date,Temperature,Return temperature,Temperature diff.,Flow,Effect\n";

				# Write all retrieved data rows to cache
				if ($sth->rows) {
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
				}
				close($fh);
			}

			# Serve cached CSV file via internal redirect for efficient delivery
			$r->internal_redirect('/' . $data_cache_path . '/' . $serial . '.csv');
			return Apache2::Const::OK;
		}
		else {
			# If requested option is unknown, respond with HTTP 404 Not Found
			return Apache2::Const::NOT_FOUND;
		}

		return Apache2::Const::OK;
	}
}

1;

__END__
