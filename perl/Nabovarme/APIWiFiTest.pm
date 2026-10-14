package Nabovarme::APIWiFiTest;

use strict;
use warnings;
use utf8;

use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::Const -compile => qw(OK HTTP_BAD_REQUEST HTTP_UNAUTHORIZED HTTP_INTERNAL_SERVER_ERROR HTTP_METHOD_NOT_ALLOWED);
use JSON ();

use Nabovarme::Db;
use Nabovarme::Admin;
use Nabovarme::MQTT_RPC;

sub handler {
	my $r = shift;
	my $admin = Nabovarme::Admin->new();

	$r->content_type("application/json; charset=utf-8");

	if ($r->method ne 'POST') {
		$r->status(Apache2::Const::HTTP_METHOD_NOT_ALLOWED);
		$r->print(JSON->new->utf8->encode({ error => 'Method not allowed' }));
		return Apache2::Const::OK;
	}

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

	# Auto-resolve mesh password if target SSID matches mesh-<serial> pattern
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

	# Escape query string reserved delimiters
	my $escaped_ssid = $ssid;
	$escaped_ssid =~ s/&/%26/g;
	$escaped_ssid =~ s/=/%3d/g;

	my $param = 'ssid=' . $escaped_ssid . '&pwd=' . $final_password;

	my $rpc = Nabovarme::MQTT_RPC->new();
	if (!$rpc->connect()) {
		$r->status(Apache2::Const::HTTP_INTERNAL_SERVER_ERROR);
		$r->print(JSON->new->utf8->encode({ error => 'Failed to connect to database queue' }));
		return Apache2::Const::OK;
	}

	my $test_result = undef;

	# Fire synchronous MQTT RPC request with a 60-second timeout in continuous mode
	my $rpc_status = $rpc->call({
		serial     => $serial,
		function   => 'test_ssid_pwd',
		param      => $param,
		stateful   => 0,
		timeout    => 60,
		continuous => 1,
		callback   => sub {
			my $res = shift;
			my $payload = (ref($res) eq 'HASH') ? $res->{param} : $res;

			# Ignore echo/request payload containing the sent parameters
			if (defined $payload && $payload =~ /status=/i) {
				$test_result = $payload;
				return 0; # Stop listening when the real test result arrives
			}

			return 1; # Keep waiting for test_ssid_pwd_result
		}
	});

	if (!defined $test_result || $test_result eq '') {
		$r->print(JSON->new->utf8->encode({
			status  => 'error',
			message => 'Meter timed out or did not respond within 60 seconds'
		}));
		return Apache2::Const::OK;
	}

	# Parse the returned query string
	my %parsed_res;
	foreach my $pair (split(/&/, $test_result)) {
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

	if ($conn_status eq 'ok' || $test_result =~ /status=ok/i) {
		$r->print(JSON->new->utf8->encode({
			status  => 'ok',
			rssi    => $rssi,
			message => 'Connection successful!'
		}));
	}
	else {
		$r->print(JSON->new->utf8->encode({
			status => 'fail',
			reason => $reason,
			rssi   => $rssi,
			error  => 'Wi-Fi connection failed'
		}));
	}

	return Apache2::Const::OK;
}

1;
