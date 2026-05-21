package Nabovarme::APISMSSent;

use strict;
use warnings;
use utf8;
use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::Const -compile => qw(OK HTTP_SERVICE_UNAVAILABLE HTTP_FORBIDDEN);
use HTTP::Date;
use JSON ();
use Time::HiRes qw(gettimeofday tv_interval); # High-precision benchmarks

use Nabovarme::Db;
use Nabovarme::Admin;
use Nabovarme::Utils;

sub handler {
	my $r = shift;
	
	my $t_start = [gettimeofday];

	my $admin = Nabovarme::Admin->new;

	# Step 1: get authenticated phone via session token
	my $auth_phone = $admin->phone_by_cookie($r);

	unless ($auth_phone) {
		$r->status(Apache2::Const::HTTP_FORBIDDEN);
		$r->content_type("application/json; charset=utf-8");
		$r->print(JSON->new->utf8->encode({ error => "Forbidden" }));
		return Apache2::Const::OK;
	}

	# Step 2: get admin groups assigned to this phone account
	my @admin_groups = $admin->groups_by_cookie($r);

	my ($dbh, $sth);
	unless ($dbh = Nabovarme::Db->my_connect) {
		$r->err_headers_out->set('Retry-After' => '60');
		return Apache2::Const::HTTP_SERVICE_UNAVAILABLE;
	}

	# =========================================================================
	# BATCH FETCH (No Perl object parsing - strings aggregated directly)
	# =========================================================================
	my $t0 = [gettimeofday];
	my %phones;
	$phones{$auth_phone} = 1;

	if (@admin_groups) {
		# Safely escape and format the collection array for the SQL IN clause
		my $group_in_clause = join(', ', map { $dbh->quote($_) } @admin_groups);

		my $sth_batch = $dbh->prepare(qq[
			SELECT sms_notification 
			FROM meters 
			WHERE `group` IN ($group_in_clause) AND sms_notification IS NOT NULL AND sms_notification != ''
			UNION ALL
			SELECT a.sms_notification 
			FROM alarms a
			INNER JOIN meters m ON m.serial = a.serial
			WHERE m.`group` IN ($group_in_clause) AND a.sms_notification IS NOT NULL AND a.sms_notification != ''
		]);
		$sth_batch->execute();

		while (my ($sms_notification) = $sth_batch->fetchrow_array) {
			for my $phone (split /\s*,\s*/, $sms_notification) {
				next unless $phone;
				$phones{$phone} = 1; # Raw string hash collection
			}
		}
	}

	my @phones = sort keys %phones;
	warn sprintf("PERF: HIGH-SPEED Step 3 (pure string aggregation) took %.4f seconds (Found %d phones across %d groups)\n", 
		tv_interval($t0), scalar(@phones), scalar(@admin_groups));

	unless (@phones) {
		$r->status(Apache2::Const::HTTP_FORBIDDEN);
		$r->content_type("application/json; charset=utf-8");
		$r->print(JSON->new->utf8->encode({ error => "Forbidden" }));
		return Apache2::Const::OK;
	}

	# Setup Content Headers & Shared Gateway Caches
	$r->content_type("application/json; charset=utf-8");
	$r->headers_out->set('Cache-Control' => 'max-age=60, public');
	$r->headers_out->set('Expires' => HTTP::Date::time2str(time + 60));
	$r->err_headers_out->add("Access-Control-Allow-Origin" => '*');

	# Build and bind target filters
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

	my $t_sql = [gettimeofday];
	$sth = $dbh->prepare($sql);
	$sth->execute();
	warn sprintf("PERF: Main SQL verification took %.4f seconds\n", tv_interval($t_sql));
	
	# Fetch authorization string layout structures
	my $sms_template = $ENV{'NOTIFICATION_SMS_CODE_MESSAGE'} || 'SMS Code: {sms_code}';
	my $escaped_template = quotemeta($sms_template);
	my $placeholder_regex = quotemeta('\{sms_code\}');
	$escaped_template =~ s/$placeholder_regex/(\\d+)/;

	# Mask internal access codes on matching profiles
	my $t_rows = [gettimeofday];
	my @rows;
	while (my $row = $sth->fetchrow_hashref) {
		if ($row->{message} =~ /^$escaped_template$/) {
			my $digits = $1;
			my $masked = '*' x length($digits);
			$row->{message} =~ s/\Q$digits\E/$masked/;
		}
		push @rows, $row;
	}
	warn sprintf("PERF: Message validation loop took %.4f seconds (Processed %d records)\n", tv_interval($t_rows), scalar(@rows));

	# Direct output transmission stream
	$r->print(
		JSON->new->utf8->canonical->encode(\@rows)
	);

	warn sprintf("PERF: === TOTAL ENDPOINT EXECUTION SPEEDS: %.4f seconds ===\n", tv_interval($t_start));
	return Apache2::Const::OK;
}

1;
