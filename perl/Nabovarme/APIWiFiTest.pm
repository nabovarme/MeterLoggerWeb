package Nabovarme::APIWiFiTest;

use strict;
use warnings;
use utf8;

use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::Const -compile => qw(OK HTTP_BAD_REQUEST HTTP_UNAUTHORIZED HTTP_INTERNAL_SERVER_ERROR HTTP_METHOD_NOT_ALLOWED);
use JSON ();
use CGI ();

use Nabovarme::Db;
use Nabovarme::Admin;
use Nabovarme::MQTT_RPC;

sub handler {
	my $r = shift;
	my $admin = Nabovarme::Admin->new();

	$r->content_type("application/json; charset=utf-8");

	# =========================================================
	# GET: Poll test status for an in-flight command ID
	# =========================================================
	if ($r->method eq 'GET') {
		my $cgi = CGI->new($r->args);
		my $command_id = $cgi->param('command_id');
		my $serial = $cgi->param('serial');

		if (!$command_id || !$serial) {
			$r->status(Apache2::Const::HTTP_BAD_REQUEST);
			$r->print(JSON->new->utf8->encode({ error => 'Missing command_id or serial' }));
			return Apache2::Const::OK;
		}

		unless ($admin->cookie_is_admin_for_serial($r, $serial)) {
			$r->status(Apache2::Const::HTTP_UNAUTHORIZED);
			$r->print(JSON->new->utf8->encode({ error => 'Unauthorized' }));
			return Apache2::Const::OK;
		}

		my $dbh = Nabovarme::Db->my_connect
			or return Apache2::Const::HTTP_INTERNAL_SERVER_ERROR;

		# Check if a response has landed in command_responses
		my $sth = $dbh->prepare(qq[
			SELECT cr.id, cr.param, cr.unix_time
			FROM command_responses cr
			WHERE cr.command_id = ?
			ORDER BY cr.id ASC LIMIT 1
		]);
		$sth->execute($command_id);

		if (my $d = $sth->fetchrow_hashref) {
			my $raw_param = $d->{param} // '';

			# If this response is just the command echo (contains no status=), ignore it and keep waiting
			if ($raw_param !~ /status=/i) {
				# Delete echo payload so it doesn't block the real result
				$dbh->do(
					qq[DELETE FROM command_responses WHERE id = ?],
					undef,
					$d->{id}
				);

				$r->print(JSON->new->utf8->encode({ status => 'pending' }));
				return Apache2::Const::OK;
			}

			# Real result arrived! Pop it from the response queue
			$dbh->do(
				qq[DELETE FROM command_responses WHERE id = ?],
				undef,
				$d->{id}
			);
			$dbh->do(
				qq[DELETE FROM command_queue WHERE id = ?],
				undef,
				$command_id
			);

			# Parse response query string parameters
			my %parsed_res;
			foreach my $pair (split(/&/, $raw_param)) {
				my ($k, $v) = split(/=/, $pair, 2);

				if (defined $k && $k ne '') {
					$v //= '';
					$v =~ tr/+/ /;
					$v =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
					$parsed_res{$k} = $v;
				}
			}

			my $conn_status = $parsed_res{status} // '';
			my $rssi = $parsed_res{rssi} // undef;
			my $reason = $parsed_res{reason} // 'none';

			if ($conn_status eq 'ok' || $raw_param =~ /status=ok/i) {
				$r->print(JSON->new->utf8->encode({
					status  => 'completed',
					result  => 'ok',
					rssi    => $rssi,
					message => 'Connection successful!'
				}));
			}
			else {
				$r->print(JSON->new->utf8->encode({
					status => 'completed',
					result => 'fail',
					reason => $reason,
					rssi   => $rssi,
					error  => 'Wi-Fi connection failed'
				}));
			}

			return Apache2::Const::OK;
		}

		# Check if the command in command_queue timed out or disappeared
		my ($cq_state) = $dbh->selectrow_array(
			qq[SELECT state FROM command_queue WHERE id = ?],
			undef,
			$command_id
		);

		if (!defined $cq_state) {
			$r->print(JSON->new->utf8->encode({
				status => 'completed',
				result => 'fail',
				error  => 'Command expired or removed from queue'
			}));
			return Apache2::Const::OK;
		}
		elsif ($cq_state eq 'timeout') {
			$dbh->do(
				qq[DELETE FROM command_queue WHERE id = ?],
				undef,
				$command_id
			);

			$r->print(JSON->new->utf8->encode({
				status => 'completed',
				result => 'fail',
				error  => 'Meter timed out without responding'
			}));
			return Apache2::Const::OK;
		}

		# Still testing...
		$r->print(JSON->new->utf8->encode({ status => 'pending' }));
		return Apache2::Const::OK;
	}

	# =========================================================
	# POST: Start the Wi-Fi test job and return command_id
	# =========================================================
	elsif ($r->method eq 'POST') {
		my $content = '';
		if (my $len = $r->headers_in->{'Content-Length'}) {
			$r->read($content, $len);
		}

		my $data = eval { JSON->new->utf8->decode($content) } || {};
		my $serial = $data->{serial};
		my $ssid = $data->{ssid};
		my $password = $data->{password} // '';

		if (!$serial || !defined $ssid) {
			$r->status(Apache2::Const::HTTP_BAD_REQUEST);
			$r->print(JSON->new->utf8->encode({ error => 'Missing serial or ssid' }));
			return Apache2::Const::OK;
		}

		unless ($admin->cookie_is_admin_for_serial($r, $serial)) {
			$r->status(Apache2::Const::HTTP_UNAUTHORIZED);
			$r->print(JSON->new->utf8->encode({ error => 'Unauthorized' }));
			return Apache2::Const::OK;
		}

		my $dbh = Nabovarme::Db->my_connect
			or return Apache2::Const::HTTP_INTERNAL_SERVER_ERROR;

		my $mesh_password = '';
		if ($ssid =~ /^mesh-(\S+)$/) {
			my $mesh_serial = $1;
			my $sth_mesh = $dbh->prepare(q[SELECT `mesh_pwd` FROM meters WHERE `serial` = ?]);
			$sth_mesh->execute($mesh_serial);

			if (my $d_mesh = $sth_mesh->fetchrow_hashref) {
				if (defined $d_mesh->{mesh_pwd} && length($d_mesh->{mesh_pwd})) {
					$mesh_password = $d_mesh->{mesh_pwd};
				}
			}
		}

		my $final_password = length($password) ? $password : $mesh_password;

		my $escaped_ssid = $ssid;
		$escaped_ssid =~ s/&/%26/g;
		$escaped_ssid =~ s/=/%3d/g;

		my $param = 'ssid=' . $escaped_ssid . '&pwd=' . $final_password;

		# Enqueue test command into command_queue (timeout set to 120s to give meter ample time)
		$dbh->do(qq[
			INSERT INTO command_queue (`serial`, `function`, `param`, `unix_time`, `state`, `has_callback`, `timeout`, `is_stateful`)
			VALUES (?, 'test_ssid_pwd', ?, UNIX_TIMESTAMP(), 'sent', 1, 120, 0)
		], undef, $serial, $param);

		my $command_id = $dbh->{mysql_insertid};

		if (!$command_id) {
			$r->status(Apache2::Const::HTTP_INTERNAL_SERVER_ERROR);
			$r->print(JSON->new->utf8->encode({ error => 'Failed to enqueue test command' }));
			return Apache2::Const::OK;
		}

		# Immediately return job details to browser
		$r->print(JSON->new->utf8->encode({
			status     => 'pending',
			command_id => $command_id,
			serial     => $serial
		}));
		return Apache2::Const::OK;
	}

	$r->status(Apache2::Const::HTTP_METHOD_NOT_ALLOWED);
	$r->print(JSON->new->utf8->encode({ error => 'Method not allowed' }));

	return Apache2::Const::OK;
}

1;
