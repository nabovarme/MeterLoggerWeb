package Nabovarme::APIWiFiUpdate;

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

	# ==========================================
	# GET: Fetch meter details for the UI form
	# ==========================================
	if ($r->method eq 'GET') {
		my $cgi = CGI->new($r->args);
		my $serial = $cgi->param('serial');
		my $ssid_qs = $cgi->param('ssid');
		my $password_qs = $cgi->param('password');

		if (!$serial) {
			$r->status(Apache2::Const::HTTP_BAD_REQUEST);
			$r->print(JSON->new->utf8->encode({ error => 'Missing serial' }));
			return Apache2::Const::OK;
		}

		unless ($admin->cookie_is_admin_for_serial($r, $serial)) {
			$r->status(Apache2::Const::HTTP_UNAUTHORIZED);
			$r->print(JSON->new->utf8->encode({ error => 'Unauthorized' }));
			return Apache2::Const::OK;
		}

		my $dbh = Nabovarme::Db->my_connect
			or return Apache2::Const::HTTP_INTERNAL_SERVER_ERROR;

		# Check if SSID matches mesh-[serial] and look up internal mesh_pwd
		my $mesh_password = '';
		my $check_ssid = $ssid_qs || '';
		
		if ($check_ssid =~ /^mesh-(\S+)$/) {
			my $mesh_serial = $1;
			my $sth_mesh = $dbh->prepare(q[SELECT `mesh_pwd` FROM meters WHERE `serial` = ?]);
			$sth_mesh->execute($mesh_serial);
			if (my $d_mesh = $sth_mesh->fetchrow_hashref) {
				if (defined $d_mesh->{mesh_pwd} && length($d_mesh->{mesh_pwd})) {
					$mesh_password = $d_mesh->{mesh_pwd};
				}
			}
		}

		my $sth = $dbh->prepare(q[SELECT `serial`, `info`, `ssid` FROM meters WHERE `serial` = ?]);
		$sth->execute($serial);

		my $info = '';
		my $db_ssid = '';
		
		if (my $d = $sth->fetchrow_hashref) {
			$info = $d->{info} || '';
			$db_ssid = $d->{ssid} || '';
		} else {
			$r->status(Apache2::Const::HTTP_BAD_REQUEST);
			$r->print(JSON->new->utf8->encode({ error => 'Meter not found' }));
			return Apache2::Const::OK;
		}

		my $final_ssid = $ssid_qs || $db_ssid;
		my $final_password = $password_qs || $mesh_password;

		$r->print(JSON->new->utf8->encode({
			status => 'ok',
			serial => $serial,
			info => $info,
			ssid => $final_ssid,
			password => $final_password
		}));
		return Apache2::Const::OK;
	}
	
	# ==========================================
	# POST: Process the WiFi credentials update
	# ==========================================
	elsif ($r->method eq 'POST') {
		my $content = '';
		if (my $len = $r->headers_in->{'Content-Length'}) {$r->read($content, $len);
		}
		
		my $data = eval { JSON->new->utf8->decode($content) } || {};
		my $serial = $data->{serial};
		my $ssid = $data->{ssid};
		my $password = $data->{password} || '';

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

		my $final_password = $password || $mesh_password;

		# URL encode '&' and '=' to prevent breaking the firmware parser
		$ssid =~ s/&/%26/g;
		$ssid =~ s/=/%3d/g;

		my $param = 'ssid=' . $ssid . '&' . 'pwd=' . $final_password;

		my $rpc = Nabovarme::MQTT_RPC->new();
		if ($rpc->connect()) {$rpc->call({
				serial   => $serial,
				function => 'set_ssid_pwd',
				param    => $param,
				stateful => 0,
				timeout  => 0
			});
			
			$rpc->call({
				serial   => $serial,
				function => 'ssid',
				param    => '1',
				stateful => 0,
				timeout  => 0
			});

			$r->print(JSON->new->utf8->encode({ status => 'ok', message => 'WiFi update commands queued' }));
			return Apache2::Const::OK;
		}

		$r->status(Apache2::Const::HTTP_INTERNAL_SERVER_ERROR);
		$r->print(JSON->new->utf8->encode({ error => 'Failed to connect to queue' }));
		return Apache2::Const::OK;
	}
	
	# Fallback for unsupported methods
	$r->status(Apache2::Const::HTTP_METHOD_NOT_ALLOWED);
	$r->print(JSON->new->utf8->encode({ error => 'Method not allowed' }));
	return Apache2::Const::OK;
}

1;
