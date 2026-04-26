package Nabovarme::PrometheusExporter;

use strict;
use warnings;

use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::Const -compile => qw(OK NOT_FOUND HTTP_INTERNAL_SERVER_ERROR);

use Nabovarme::Db;
use Nabovarme::Utils;

# --- metric query ---
sub get_sms_totals {
	my $dbh = shift;

	my %totals = (
		sent     => 0,
		received => 0,
	);

	return \%totals unless $dbh;

	my $sth = $dbh->prepare(q{
		SELECT direction, COUNT(*)
		FROM sms_messages
		GROUP BY direction
	});

	eval {
		$sth->execute();
	};

	if ($@) {
		log_info("SQL error: $@");
		return \%totals;
	}

	while (my ($direction, $count) = $sth->fetchrow_array) {
		$totals{$direction} = $count;
	}

	return \%totals;
}

# --- Apache mod_perl handler ---
sub handler {
	my $r = shift;

	# Connect to DB (same style as APIMeters)
	my $dbh = Nabovarme::Db->my_connect();

	unless ($dbh) {
		log_info("DB connection failed");
		return Apache2::Const::HTTP_INTERNAL_SERVER_ERROR;
	}

	my $totals = get_sms_totals($dbh);

	my $output = <<"EOF";
# HELP sms_messages_sent_total Total number of sent SMS messages
# TYPE sms_messages_sent_total counter
sms_messages_sent_total $totals->{sent}

# HELP sms_messages_received_total Total number of received SMS messages
# TYPE sms_messages_received_total counter
sms_messages_received_total $totals->{received}
EOF

	$r->print($output);

	return Apache2::Const::OK;
}

1;
