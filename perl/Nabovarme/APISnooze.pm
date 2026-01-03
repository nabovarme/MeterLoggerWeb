package Nabovarme::APISnooze;

use strict;
use warnings;
use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::Const -compile => qw(OK HTTP_SERVICE_UNAVAILABLE);
use DBI;
use utf8;
use Data::Dumper;

use Nabovarme::Db;

sub handler {
my $r = shift;
	$r->content_type("application/json; charset=utf-8");
	$r->headers_out->set('Cache-Control' => 'no-cache, no-store, must-revalidate');
	$r->headers_out->set('Pragma' => 'no-cache');
	$r->headers_out->set('Expires' => '0');
	$r->err_headers_out->add("Access-Control-Allow-Origin" => '*');

	# Extract serial/snooze/auth from PATH_INFO: /serial/snooze/auth
	my $path = $r->path_info || '';	
	$path =~ s{^/}{};
	my ($serial, $snooze, $auth) = split('/', $path);

	warn Dumper ($serial, $snooze, $auth);
	warn Dumper $r->uri;       # full URI, e.g. /api/alarms/snooze/9999995/1800/5b4489767be10db2
	warn Dumper $r->location;  # the location path that matched, e.g. /api/alarms/snooze
	warn Dumper $r->path_info; # the extra path after the location

	my $response = { authorized => 0 };
	my ($dbh, $sth, $d);

	if ($serial && $auth && ($dbh = Nabovarme::Db->my_connect)) {
		my $quoted_serial = $dbh->quote($serial);
		my $quoted_auth   = $dbh->quote($auth);

		$sth = $dbh->prepare(qq[
			SELECT * FROM alarms
			WHERE serial LIKE $quoted_serial
			  AND snooze_auth_key LIKE $quoted_auth
		]);
		$sth->execute;

		if ($sth->rows && ($d = $sth->fetchrow_hashref)) {
			$response->{authorized} = 1;

			if (defined $snooze) {
				# Update the alarm's snooze
#				$dbh->do(qq[
#					UPDATE alarms
#					SET
#						snooze = ] . $dbh->quote($snooze) . qq[,
#						alarm_count = 0,
#						last_notification = UNIX_TIMESTAMP()
#					WHERE id = ] . $dbh->quote($d->{id})
#				]) || warn $!;

				# Refresh row after update
				$sth->execute;
				$d = $sth->fetchrow_hashref;
			}

			$response->{alarm} = prepare_alarm_data($d);
			$response->{alarm}->{snooze_human} = human_duration($d->{snooze});
		}
	}

	$r->print(encode_json($response));
	return Apache2::Const::OK;
}

# Convert seconds into human-readable string
sub human_duration {
	my $seconds = shift;
	return '' unless defined $seconds;

	my $value;
	my $unit;

	if ($seconds < 60) {
		$value = $seconds;
		$unit  = 'second';
	} elsif ($seconds < 3600) {
		$value = int($seconds / 60);
		$unit  = 'minute';
	} elsif ($seconds < 86400) {
		$value = int($seconds / 3600);
		$unit  = 'hour';
	} elsif ($seconds < 604800) {
		$value = int($seconds / 86400);
		$unit  = 'day';
	} elsif ($seconds < 2678400) {
		$value = int($seconds / 604800);
		$unit  = 'week';
	} else {
		$value = int($seconds / 2678400);
		$unit  = 'month';
	}

	$unit .= 's' if $value != 1;
	return "$value $unit";
}

sub encode_json {
	my ($data) = @_;
	require JSON::PP;
	return JSON::PP->new->utf8->encode($data);
}

1;
