package Nabovarme::APIPaymentsPending;

use strict;
use warnings;
use utf8;
use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::Const -compile => qw(OK HTTP_SERVICE_UNAVAILABLE);
use HTTP::Date;
use JSON::XS;

use Nabovarme::Db;
use Nabovarme::Utils;

sub handler {
	my $r = shift;
	my ($dbh, $sth);

	if ($dbh = Nabovarme::Db->my_connect) {
		$r->content_type("application/json; charset=utf-8");
		# Cache for 60 seconds
		$r->headers_out->set('Cache-Control' => 'max-age=60, public');
		$r->headers_out->set('Expires' => HTTP::Date::time2str(time + 60));
		$r->err_headers_out->add("Access-Control-Allow-Origin" => '*');

		my $sql = q[
			SELECT meters.`serial`, meters.`info`, command_queue.`param` AS open_until, FROM_UNIXTIME(command_queue.`unix_time`, '%e.%c.%Y %H:%i') AS time
			FROM meters, command_queue
			WHERE meters.`serial` = command_queue.`serial`
			  AND command_queue.`function` like 'open_until%'
			ORDER BY command_queue.`unix_time` DESC
		];

		$sth = $dbh->prepare($sql);
		$sth->execute();

		my $json_obj = JSON::XS->new->utf8->canonical;

		# Collect encoded rows (JSON strings)
		my @encoded_rows;
		while (my $row = $sth->fetchrow_hashref) {
			# Format open_until with 2 decimals, then force numeric context
			$row->{open_until} = sprintf("%.2f", $row->{open_until}) + 0;

			# --- Fetch time_remaining_hours and last_updated from meters_state ---
			my ($time_remaining_hours, $last_updated) = $dbh->selectrow_array(
				qq[
					SELECT ms.time_remaining_hours, m.last_updated
					FROM meters_state ms
					JOIN meters m ON m.serial = ms.serial
					WHERE ms.serial = ?
				],
				undef,
				$row->{serial}
			);

			if (defined $time_remaining_hours && defined $last_updated) {
				# Calculate hours since last update
				my $hours_since_update = (time() - $last_updated) / 3600;

				# Adjust time_remaining_hours for offline period
				my $adjusted_hours = $time_remaining_hours - $hours_since_update;
				$row->{time_remaining_hours_offline_compensated} = sprintf("%.2f", $adjusted_hours) + 0;

				# --- Debug logging ---
				log_warn(
					"$row->{serial}: raw time_remaining_hours=$time_remaining_hours, " .
					"last_updated=$last_updated, hours_since_update=$hours_since_update, " .
					"time_remaining_hours_offline_compensated=" . $row->{time_remaining_hours_offline_compensated}
				);
			} else {
				$row->{time_remaining_hours_offline_compensated} = undef;
				log_warn("$row->{serial}: time_remaining_hours or last_updated undefined, cannot compensate");
			}

			push @encoded_rows, $json_obj->encode($row);
		}

		# Join all encoded JSON objects with commas inside a JSON array
		$r->print('[' . join(',', @encoded_rows) . ']');

		return Apache2::Const::OK;
	}

	$r->err_headers_out->set('Retry-After' => '60');

	return Apache2::Const::HTTP_SERVICE_UNAVAILABLE;
}

1;
