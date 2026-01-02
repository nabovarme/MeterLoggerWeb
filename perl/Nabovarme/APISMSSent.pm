package Nabovarme::APISMSSent;

use strict;
use warnings;
use utf8;
use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::Const -compile => qw(OK HTTP_SERVICE_UNAVAILABLE HTTP_FORBIDDEN);
use HTTP::Date;
use JSON::XS;

use Nabovarme::Db;
use Nabovarme::Admin;
use Nabovarme::Utils;

sub handler {
	my $r = shift;

	my $admin = Nabovarme::Admin->new;
	my @serials = $admin->serials_by_cookie($r);
	use Data::Dumper; warn "APISMSSent: serials allowed for cookie: " . Dumper(\@serials);

	# If no serials allowed, deny access
	unless (@serials) {
		$r->status(Apache2::Const::HTTP_FORBIDDEN);
		$r->content_type("application/json; charset=utf-8");
		$r->print(JSON::XS->new->utf8->encode({ error => "Forbidden" }));
		return Apache2::Const::OK;
	}

	my ($dbh, $sth);

	if ($dbh = Nabovarme::Db->my_connect) {
		$r->content_type("application/json; charset=utf-8");
		# Cache for 60 seconds
		$r->headers_out->set('Cache-Control' => 'max-age=60, public');
		$r->headers_out->set('Expires' => HTTP::Date::time2str(time + 60));
		$r->err_headers_out->add("Access-Control-Allow-Origin" => '*');

		# Step 1: get phones for allowed serials
		my $serials_in = join(',', map { $dbh->quote($_) } @serials);
		my $sth_phones = $dbh->prepare(qq[
			SELECT DISTINCT sms_notification
			FROM meters
			WHERE serial IN ($serials_in)
			  AND sms_notification IS NOT NULL
			  AND sms_notification != ''
		]);
		$sth_phones->execute();

		my @phones;
		while (my $row = $sth_phones->fetchrow_hashref) {
			# sms_notification may be comma-separated, split and trim
			push @phones, map { s/^\s+|\s+$//gr } split /,/, $row->{sms_notification};
		}

		# Deduplicate phones
		my %seen;
		@phones = grep { !$seen{$_}++ } @phones;
		warn "APISMSSent: phones used for query: " . join(', ', @phones);

		unless (@phones) {
			$r->status(Apache2::Const::HTTP_FORBIDDEN);
			$r->print(JSON::XS->new->utf8->encode({ error => "Forbidden" }));
			return Apache2::Const::OK;
		}

		# Step 2: select SMS messages only for allowed phones using wildcards
		my @like_clauses = map { "phone LIKE " . $dbh->quote("%$_%") } @phones;
		my $sql = qq[
			SELECT
				direction,
				phone,
				message,
				FROM_UNIXTIME(unix_time) as `time`
			FROM sms_messages
			WHERE unix_time >= UNIX_TIMESTAMP(NOW() - INTERVAL 1 YEAR)
			  AND unix_time < UNIX_TIMESTAMP()
			  AND ( ] . join(' OR ', @like_clauses) . q[ )
			ORDER BY unix_time DESC
			LIMIT 100;
		];
		warn "APISMSSent: SQL to fetch messages: $sql";

		$sth = $dbh->prepare($sql);
		$sth->execute();

		my $json_obj = JSON::XS->new->utf8->canonical;

		# Collect encoded rows (JSON strings)
		my @encoded_rows;
		while (my $row = $sth->fetchrow_hashref) {
			# Mask SMS codes
			$row->{message} =~ s/(SMS Code: )(\d+)/$1 . ('*' x length($2))/e;
			push @encoded_rows, $json_obj->encode($row);
		}

		warn "APISMSSent: total SMS messages fetched: " . scalar(@encoded_rows);
		# Join all encoded JSON objects with commas inside a JSON array
		$r->print('[' . join(',', @encoded_rows) . ']');

		return Apache2::Const::OK;
	}

	$r->err_headers_out->set('Retry-After' => '60');
	return Apache2::Const::HTTP_SERVICE_UNAVAILABLE;
}

1;
