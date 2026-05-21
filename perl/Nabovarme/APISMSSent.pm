package Nabovarme::APISMSSent;

use strict;
use warnings;
use utf8;
use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::Const -compile => qw(OK HTTP_SERVICE_UNAVAILABLE HTTP_FORBIDDEN);
use HTTP::Date;
use JSON ();

use Nabovarme::Db;
use Nabovarme::Admin;
use Nabovarme::Utils;

sub handler {
	my $r = shift;

	my $admin = Nabovarme::Admin->new;

	# Step 1: get authenticated phone
	my $auth_phone = $admin->phone_by_cookie($r);

	unless ($auth_phone) {
		$r->status(Apache2::Const::HTTP_FORBIDDEN);
		$r->content_type("application/json; charset=utf-8");
		$r->print(JSON->new->utf8->encode({ error => "Forbidden" }));
		return Apache2::Const::OK;
	}

	# Step 2: get admin groups for this phone
	my @admin_groups = $admin->groups_by_cookie($r);

	# Step 3: build union set of phones
	my %phones;
	$phones{$auth_phone} = 1;

	for my $group (@admin_groups) {
		my @group_phones = $admin->phones_by_group($group);
		$phones{$_} = 1 for @group_phones;
	}

	my @phones = sort keys %phones;
#	warn "APISMSSent: final phone set = " . join(', ', @phones);

	unless (@phones) {
		$r->status(Apache2::Const::HTTP_FORBIDDEN);
		$r->content_type("application/json; charset=utf-8");
		$r->print(JSON->new->utf8->encode({ error => "Forbidden" }));
		return Apache2::Const::OK;
	}

	my ($dbh, $sth);

	if ($dbh = Nabovarme::Db->my_connect) {
		$r->content_type("application/json; charset=utf-8");

		# Cache for 60 seconds
		$r->headers_out->set('Cache-Control' => 'max-age=60, public');
		$r->headers_out->set('Expires' => HTTP::Date::time2str(time + 60));
		$r->err_headers_out->add("Access-Control-Allow-Origin" => '*');

		# Step 4: Quote each phone number and create a comma-separated list
		my $in_clause_items = join(', ', map { $dbh->quote($_) } @phones);

		my $sql = qq[
			SELECT
				direction,
				phone,
				message,
				FROM_UNIXTIME(unix_time, '%e.%c.%Y %H:%i') AS `time`
			FROM sms_messages
			WHERE unix_time >= UNIX_TIMESTAMP(NOW() - INTERVAL 3 MONTH)
				AND unix_time < UNIX_TIMESTAMP()
				AND phone IN ($in_clause_items)
			ORDER BY unix_time DESC
		];

		$sth = $dbh->prepare($sql);
		$sth->execute();
		
		# Fetch the template or use fallback
		my $sms_template = $ENV{'NOTIFICATION_SMS_CODE_MESSAGE'} || 'SMS Code: {sms_code}';

		# Escape the template text safely, but leave our placeholder distinct
		my $escaped_template = quotemeta($sms_template);

		# Turn the escaped placeholder into a digit-capturing regex group: (\d+)
		my $placeholder_regex = quotemeta('\{sms_code\}');
		$escaped_template =~ s/$placeholder_regex/(\\d+)/;

		my @rows;
		while (my $row = $sth->fetchrow_hashref) {
			# Match the message against our dynamic template pattern
			if ($row->{message} =~ /^$escaped_template$/) {
				# $1 contains the raw digits captured by (\d+)
				my $digits = $1;
				my $masked = '*' x length($digits);
		
				# Substitute only the digit portion inside the message string
				$row->{message} =~ s/\Q$digits\E/$masked/;
			}

			push @rows, $row;
		}

		$r->print(
			JSON->new->utf8->canonical->encode(\@rows)
		);

		return Apache2::Const::OK;
	}

	$r->err_headers_out->set('Retry-After' => '60');
	return Apache2::Const::HTTP_SERVICE_UNAVAILABLE;
}

1;
