package Nabovarme::APIWIFIPending;

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
			SELECT meters.`serial`, meters.`info`, command_queue.`param` AS ssid, FROM_UNIXTIME(command_queue.`unix_time`, '%e.%c.%Y %H:%i') AS time
			FROM meters, command_queue
			WHERE meters.`serial` = command_queue.`serial`
			  AND command_queue.`function` = 'set_ssid_pwd'
			  AND command_queue.`state` = 'sent'
			ORDER BY command_queue.`unix_time` DESC
		];

		$sth = $dbh->prepare($sql);
		$sth->execute();

		my $json_obj = JSON::XS->new->utf8->canonical;

		# Collect encoded rows (JSON strings)
		my @encoded_rows;
		while (my $row = $sth->fetchrow_hashref) {
			# Format ssid=network&pwd=pass
			($row->{ssid}) = $row->{ssid} =~ /ssid=([^&]+)/;
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
