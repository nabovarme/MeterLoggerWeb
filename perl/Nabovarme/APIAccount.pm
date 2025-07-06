package Nabovarme::APIAccount;

use strict;
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
#			$row->{payment_time} = $row->{payment_time} * 1000;

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

		# Encode the entire array of records as a JSON array and print it to the response
		$r->print($json_obj->encode(\@encoded_rows));

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
