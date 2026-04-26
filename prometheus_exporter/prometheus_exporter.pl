#!/usr/bin/perl -w
use strict;
use warnings;

use HTTP::Daemon;
use HTTP::Status;
use HTTP::Response;
use HTTP::Headers;

use Nabovarme::Db;
use Nabovarme::Utils;

my $PORT = $ENV{'EXPORTER_PORT'} || 9101;

log_info("starting SMS Prometheus exporter");

# --- DB connection ---
my $dbh = Nabovarme::Db->my_connect
	or log_die("can't connect to db");

$dbh->{'mysql_auto_reconnect'} = 1;
log_info("connected to db");

# --- shutdown handling ---
my $RUNNING = 1;

$SIG{INT} = sub {
	log_info("received SIGINT, shutting down");
	$RUNNING = 0;
};

$SIG{TERM} = sub {
	log_info("received SIGTERM, shutting down");
	$RUNNING = 0;
};

sub get_sms_totals {
	my %totals = (
		sent     => 0,
		received => 0,
	);

	my $sth = $dbh->prepare(q{
		SELECT direction, COUNT(*) 
		FROM sms_messages
		GROUP BY direction
	});
	$sth->execute();
	while (my ($direction, $count) = $sth->fetchrow_array) {
		$totals{$direction} = $count;
	}
	return \%totals;
}

# --- HTTP server ---
my $d = HTTP::Daemon->new(
	LocalPort => $PORT,
	Reuse     => 1,
) or log_die("cannot start HTTP server");

log_info("listening on " . $d->url . "metrics");

while ($RUNNING) {
	my $c = $d->accept;

	next unless $c;

	while (my $r = $c->get_request) {

		if ($r->method eq 'GET' && $r->uri->path eq '/metrics') {

			my $totals = get_sms_totals();

			my $metrics = <<"EOF";
# HELP sms_messages_sent_total Total number of sent SMS messages
# TYPE sms_messages_sent_total counter
sms_messages_sent_total $totals->{sent}

# HELP sms_messages_received_total Total number of received SMS messages
# TYPE sms_messages_received_total counter
sms_messages_received_total $totals->{received}
EOF

			my $headers = HTTP::Headers->new(
				'Content-Type' => 'text/plain; version=0.0.4; charset=utf-8'
			);

			$c->send_response(
				HTTP::Response->new(RC_OK, "OK", $headers, $metrics)
			);

		} else {
			$c->send_error(RC_NOT_FOUND);
		}

	}
	$c->close;
}

log_info("closing HTTP server");
$d->close if $d;
