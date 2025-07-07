package Nabovarme::APIAccount;

use strict;
use utf8;
use Data::Dumper;
use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::Const;
use HTTP::Date qw(time2str);
use JSON::XS;

use lib qw( /etc/apache2/perl );
use Nabovarme::Db;
use Nabovarme::Utils;

sub handler {
	my $r = shift;
	my ($dbh, $sth, $d);

	# Get cache path from Apache config or fallback to default '/cache'
	my $data_cache_path = $r->dir_config('DataCachePath') || '/cache';

	# Get the Apache document root path (not currently used but may be useful)
	my $document_root = $r->document_root();

	# Extract the serial number from the URI (last path component)
	my ($serial) = $r->uri =~ m|([^/]+)$|;

	my $quoted_serial;
	my $setup_value = 0;

	# Connect to the database using Nabovarme::Db module
	if ($dbh = Nabovarme::Db->my_connect) {

		# Set response content type to JSON with UTF-8 encoding
		$r->content_type("application/json; charset=utf-8");

		# Set caching headers: public cache for 60 seconds
		$r->headers_out->set('Cache-Control' => 'max-age=60, public');
		$r->headers_out->set('Expires' => HTTP::Date::time2str(time + 60));

		# Add CORS header to allow all origins
		$r->err_headers_out->add("Access-Control-Allow-Origin" => '*');

		# Debug: dump the serial to error log
		warn Dumper $serial;

		# Quote the serial for safe use in SQL (prevents injection)
		$quoted_serial = $dbh->quote($serial);
		
		# --- New query to get last sample values ---
		my $sth_last_energy = $dbh->prepare(qq[
			SELECT hours, volume, energy
			FROM samples_cache
			WHERE serial = $quoted_serial
			ORDER BY `unix_time` DESC LIMIT 1
		]);
		$sth_last_energy->execute;
		my ($last_hours, $last_volume, $last_energy) = $sth_last_energy->fetchrow_array;

		# --- New query to get summary values ---
		my $sth_summary = $dbh->prepare(qq[
			SELECT
				m.serial,
	
				-- Calculate remaining kilowatt-hours:
				-- paid_kwh - consumed energy + any setup (initial) value
				ROUND(
					IFNULL(paid_kwh_table.paid_kwh, 0) - IFNULL(latest_sc.energy, 0) + m.setup_value,
					2
				) AS kwh_left,
	
				-- Estimate time left in hours:
				-- kwh_left / current power usage (effect), if effect > 0
				ROUND(
					IF(latest_sc.effect > 0,
						(IFNULL(paid_kwh_table.paid_kwh, 0) - IFNULL(latest_sc.energy, 0) + m.setup_value) / latest_sc.effect,
						NULL
					),
					2
				) AS time_left_hours,
	
				-- Energy used in the last 24 hours:
				-- difference between latest and previous day's energy readings
				ROUND(
					latest_sc.energy - prev_sc.energy,
					2
				) AS energy_last_day,
	
				-- Average hourly power usage for the last 24 hours:
				-- energy_last_day divided by 24 hours
				ROUND(
					(latest_sc.energy - prev_sc.energy) / 24,
					2
				) AS avg_energy_last_day
	
			FROM meters m
	
			-- Join the latest available sample for each serial
			LEFT JOIN (
				SELECT sc1.*
				FROM samples_cache sc1
				INNER JOIN (
					-- Get the most recent timestamp per serial
					SELECT serial, MAX(unix_time) AS max_time
					FROM samples_cache
					GROUP BY serial
				) latest ON sc1.serial = latest.serial AND sc1.unix_time = latest.max_time
			) latest_sc ON m.serial = latest_sc.serial
	
			-- Join the latest sample from ~24 hours ago for each serial
			LEFT JOIN (
				SELECT sc2.*
				FROM samples_cache sc2
				INNER JOIN (
					-- Get the latest sample *before* 24 hours ago per serial
					SELECT serial, MAX(unix_time) AS max_time
					FROM samples_cache
					WHERE unix_time <= UNIX_TIMESTAMP(NOW()) - 86400  -- 86400 seconds = 24 hours
					GROUP BY serial
				) prev ON sc2.serial = prev.serial AND sc2.unix_time = prev.max_time
			) prev_sc ON m.serial = prev_sc.serial
	
			-- Join total energy purchased (converted from money to kWh) per serial
			LEFT JOIN (
				SELECT serial, SUM(amount / price) AS paid_kwh
				FROM accounts
				GROUP BY serial
			) paid_kwh_table ON m.serial = paid_kwh_table.serial
	
			-- Filter only heat-related meter types, and target a specific serial
			WHERE m.type IN ('heat', 'heat_supply', 'heat_sub')
			  AND m.serial = $quoted_serial;
		]);
		$sth_summary->execute();
		$d = $sth_summary->fetchrow_hashref || {};

		# Prepare SQL statement to select account and related meter info
		my $sth = $dbh->prepare(qq[
			SELECT 
				m.info,
				a.*
			FROM 
				accounts a
			LEFT JOIN 
				meters m ON a.serial = m.serial
			WHERE 
				a.serial = $quoted_serial
			ORDER BY 
				a.payment_time ASC
		]);
		$sth->execute();

		# Create a JSON::XS object for encoding data with UTF-8 and sorted keys
		my $json_obj = JSON::XS->new->utf8->canonical;

		my @encoded_rows;

		# Fetch each row from the query result and build a hashref for JSON output
		while (my $row = $sth->fetchrow_hashref) {
			# Convert payment_time from seconds to milliseconds (JavaScript timestamp format)
	#	   $row->{payment_time} = $row->{payment_time} * 1000;

			# Push a hashref with selected keys into the array for encoding later
			push @encoded_rows, {
				id           => $row->{id},
				type         => $row->{type},
				payment_time => $row->{payment_time},
				info         => $row->{info},
				amount       => $row->{amount},
				price        => $row->{price}
			};
		}

		# Encode the entire response with summary keys and payments array
		my $response = {
			kwh_left            => $d->{kwh_left} || 0,
			time_left_hours     => $d->{time_left_hours} || 0,
			energy_last_day     => $d->{energy_last_day} || 0,
			time_left_str       => ($d->{energy_last_day} > 0) ? "$d->{energy_last_day}" : '∞',
			avg_energy_last_day => $d->{avg_energy_last_day},
			last_hours          => $last_hours,
			last_volume         => $last_volume,
			last_energy         => $last_energy,
			account             => \@encoded_rows,
		};

		$r->print($json_obj->encode($response));

		return Apache2::Const::OK;
	}
	else {
		# Database connection failed: return 500 Internal Server Error with plain text message
		$r->status(Apache2::Const::SERVER_ERROR);
		$r->content_type('text/plain');
		$r->print("Database connection failed.\n");
		return Apache2::Const::OK;
	}
}

1;

__END__
