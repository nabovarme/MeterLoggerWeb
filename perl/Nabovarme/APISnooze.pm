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

	my $response = { authorized => 0 };
	my ($dbh, $sth, $d);

	# Extract path info 
	my $path = $r->path_info;
	$path =~ s{^/}{};

	# Split into auth and optional snooze
	my ($auth, $snooze) = split('/', $path);

	warn Dumper($auth, $snooze);

	# Connect and find alarm by auth
	if ($auth && ($dbh = Nabovarme::Db->my_connect)) {
		my $quoted_auth = $dbh->quote($auth);

		$sth = $dbh->prepare(qq[
			SELECT * FROM alarms
			WHERE snooze_auth_key LIKE $quoted_auth
			LIMIT 1
		]);
		$sth->execute;

		if ($sth->rows && ($d = $sth->fetchrow_hashref)) {
			$response->{authorized} = 1;

			# Update snooze if provided
			if (defined $snooze) {
				$dbh->do(qq{
					UPDATE alarms
					SET
						snooze = } . $dbh->quote($snooze) . qq{,
						alarm_count = 0,
						last_notification = UNIX_TIMESTAMP()
					WHERE id = } . $d->{id}
				) || warn $!;

				# Refresh row
				$sth->execute;
				$d = $sth->fetchrow_hashref;
			}

			# Return alarm data
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

sub prepare_alarm_data {
	my ($alarm) = @_;
	return {
		id => $alarm->{id} // '',
		serial => $alarm->{serial} // '',
		info => $alarm->{info} // '',
		sms_notification => $alarm->{sms_notification} // '',
		condition => $alarm->{condition} // '',
		condition_error => $alarm->{condition_error} // '',
		alarm_state => $alarm->{alarm_state} // '',
		enabled => $alarm->{enabled} // '',
		repeat => $alarm->{repeat} // '',
		snooze => $alarm->{snooze} // '',
		comment => $alarm->{comment} // '',
	};
}

sub encode_json {
	my ($data) = @_;
	require JSON::PP;
	return JSON::PP->new->utf8->encode($data);
}

1;
