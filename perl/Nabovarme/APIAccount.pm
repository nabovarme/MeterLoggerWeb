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
	my ($dbh, $sth);

	# Extract the serial number from the last path component of the request URI
	my ($serial) = $r->uri =~ m|([^/]+)$|;

	my $quoted_serial;
	my $setup_value = 0;

	# Attempt database connection
	if ($dbh = Nabovarme::Db->my_connect) {

		# Set response content type to JSON with UTF-8 encoding
		$r->content_type("application/json; charset=utf-8");

		# Add caching headers (60-second public cache)
		$r->headers_out->set('Cache-Control' => 'max-age=60, public');
		$r->headers_out->set('Expires' => HTTP::Date::time2str(time + 60));

		# Allow CORS from any origin
		$r->err_headers_out->add("Access-Control-Allow-Origin" => '*');

		# Safely quote serial number for SQL usage
		$quoted_serial = $dbh->quote($serial);

		# --- Retrieve most recent sample data for this meter ---
		my $sth_last_energy = $dbh->prepare(qq[
			SELECT hours, volume, energy
			FROM samples_cache
			WHERE serial = $quoted_serial
			ORDER BY `unix_time` DESC LIMIT 1
		]);
		$sth_last_energy->execute;
		my ($last_hours, $last_volume, $last_energy) = $sth_last_energy->fetchrow_array;

		# --- Compute summary metrics including kWh left, estimated time, and usage stats ---
		my $sth_summary = $dbh->prepare(qq[
			SELECT
				m.serial,

				-- Remaining energy: paid - consumed + setup
				ROUND(
					IFNULL(paid_kwh_table.paid_kwh, 0) - IFNULL(latest_sc.energy, 0) + m.setup_value,
					2
				) AS kwh_left,

				-- Estimated time left (hours), only if effect > 0
				ROUND(
					IF(latest_sc.effect > 0,
						(IFNULL(paid_kwh_table.paid_kwh, 0) - IFNULL(latest_sc.energy, 0) + m.setup_value) / latest_sc.effect,
						NULL
					),
					2
				) AS time_left_hours,

				-- Energy used in last 24 hours
				ROUND(
					latest_sc.energy - prev_sc.energy,
					2
				) AS energy_last_day,

				-- Average power usage in last 24 hours (kWh/hour)
				ROUND(
					(latest_sc.energy - prev_sc.energy) / 24,
					2
				) AS avg_energy_last_day

			FROM meters m

			-- Join most recent sample
			LEFT JOIN (
				SELECT sc1.*
				FROM samples_cache sc1
				INNER JOIN (
					SELECT serial, MAX(unix_time) AS max_time
					FROM samples_cache
					GROUP BY serial
				) latest ON sc1.serial = latest.serial AND sc1.unix_time = latest.max_time
			) latest_sc ON m.serial = latest_sc.serial

			-- Join sample from ~24 hours ago
			LEFT JOIN (
				SELECT sc2.*
				FROM samples_cache sc2
				INNER JOIN (
					SELECT serial, MAX(unix_time) AS max_time
					FROM samples_cache
					WHERE unix_time <= UNIX_TIMESTAMP(NOW()) - 86400
					GROUP BY serial
				) prev ON sc2.serial = prev.serial AND sc2.unix_time = prev.max_time
			) prev_sc ON m.serial = prev_sc.serial

			-- Join paid energy (money converted to kWh)
			LEFT JOIN (
				SELECT serial, SUM(amount / price) AS paid_kwh
				FROM accounts
				GROUP BY serial
			) paid_kwh_table ON m.serial = paid_kwh_table.serial

			-- Only process heat-related meters for the requested serial
			WHERE m.type IN ('heat', 'heat_supply', 'heat_sub')
			  AND m.serial = $quoted_serial;
		]);
		$sth_summary->execute();
		my $summary_row = $sth_summary->fetchrow_hashref || {};

		# --- Retrieve account records for this serial, with meter info ---
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
				a.payment_time DESC
		]);
		$sth->execute();

		# Use JSON::XS for consistent, UTF-8 encoded JSON output
		my $json_obj = JSON::XS->new->utf8->canonical;

		my @encoded_rows;

		# Extract relevant fields from account rows
		while (my $row = $sth->fetchrow_hashref) {
			push @encoded_rows, {
				id           => $row->{id},
				type         => $row->{type},
				payment_time => $row->{payment_time},
				info         => $row->{info},
				amount       => $row->{amount},
				price        => $row->{price}
			};
		}

		# Construct final response payload
		my $response = {
			kwh_left            => $summary_row->{kwh_left} || 0,
			time_left_hours     => $summary_row->{time_left_hours} || 0,
			energy_last_day     => $summary_row->{energy_last_day} || 0,
			time_left_str       => ($summary_row->{avg_energy_last_day} > 0) ? rounded_duration($summary_row->{kwh_left} / $summary_row->{avg_energy_last_day} * 3600) : '∞',
			avg_energy_last_day     => $summary_row->{avg_energy_last_day},
			last_hours          => $last_hours,
			last_volume         => $last_volume,
			last_energy         => $last_energy,
			account             => \@encoded_rows,
		};

		# Output the JSON response
		$r->print($json_obj->encode($response));

		return Apache2::Const::OK;
	}
	else {
		# If DB connection fails, return 500 with plain error text
		$r->status(Apache2::Const::SERVER_ERROR);
		$r->content_type('text/plain');
		$r->print("Database connection failed.\n");
		return Apache2::Const::OK;
	}
}

1;

__END__
