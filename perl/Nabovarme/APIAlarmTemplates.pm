package Nabovarme::APIAlarmTemplates;

use strict;
use warnings;
use utf8;
use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::Const -compile => qw(OK HTTP_SERVICE_UNAVAILABLE HTTP_INTERNAL_SERVER_ERROR);
use JSON qw(encode_json);

use Nabovarme::Utils qw(log_debug log_warn);
use Nabovarme::Db;

sub handler {
	my $r = shift;

	my $dbh = Nabovarme::Db->my_connect;
	unless ($dbh) {
		log_warn("[APIAlarmTemplates] Could not connect to database");
		$r->err_headers_out->set('Retry-After' => '60');
		return Apache2::Const::HTTP_SERVICE_UNAVAILABLE;
	}

	$r->content_type("application/json; charset=utf-8");
	$r->headers_out->set('Cache-Control' => 'no-cache, no-store, must-revalidate');

	my $templates = [];

	eval {
		my $sth =$dbh->prepare(qq[
			SELECT 
				id,
				description AS label,
				`condition`
			FROM alarm_templates
			ORDER BY id ASC
		]);
		$sth->execute();

		while (my $row =$sth->fetchrow_hashref) {
			push @$templates, {
				id        => int($row->{id}),
				label     => $row->{label} // '',
				condition => $row->{condition} // '',
			};
		}
	};

	if ($@) {
		my $err =$@;
		log_warn("[APIAlarmTemplates] SQL error fetching templates: " . ($err || ''));
		$r->status(Apache2::Const::HTTP_INTERNAL_SERVER_ERROR);$r->print(encode_json({ success => 0, error => "Database query failed" }));
		return Apache2::Const::OK;
	}

	log_debug(sprintf("[APIAlarmTemplates] Loaded %d alarm template(s)", scalar(@$templates)));

	$r->print(encode_json($templates));
	return Apache2::Const::OK;
}

1;
