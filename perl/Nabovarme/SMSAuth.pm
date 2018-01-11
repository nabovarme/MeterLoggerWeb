package Nabovarme::SMSAuth;

use strict;
use Data::Dumper;
use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::SubRequest ();
use Apache2::Const;
use CGI::Cookie ();
use CGI;
use Math::Random::Secure qw(rand);
use DBI;
use utf8;

use File::Temp qw( tempfile );
use File::Basename;
use File::Copy;
use Encode qw( encode decode );

use constant SMS_SPOOL_DIR => '/var/www/nabovarme/sms_spool';

use lib qw( /etc/apache2/perl );
#use lib qw( /opt/local/apache2/perl );
use Nabovarme::Db;

sub handler {
	my $r = shift;

	my ($dbh, $sth, $d);
	$dbh = Nabovarme::Db->my_connect || die $!;

	my $passed_cookie = $r->headers_in->{Cookie} || '';
	if ($passed_cookie) {
		# first handle special url's
		if ($r->uri =~ /logout/i) {
			# user wants to logout
			return logout_handler($r);
		}
#		elsif ($r->uri =~ /login/i) {
#			return login_handler($r);
#		}
#		elsif ($r->uri =~ /sms_code/i) {
#			return login_handler($r);
#		}
		else {
			# chack if the user is auth'ed
			my $passed_cookie_token;
			if ($passed_cookie) {
				($passed_cookie_token) = $passed_cookie =~ /auth_token=(.*)/;
			}

			my $quoted_passed_cookie_token = $dbh->quote($passed_cookie_token);
			$sth = $dbh->prepare(qq[SELECT `auth_state` FROM sms_auth WHERE `cookie_token` LIKE $quoted_passed_cookie_token AND `auth_state` LIKE 'sms_code_verified' LIMIT 1]);
			$sth->execute;
			if ($d = $sth->fetchrow_hashref) {
				return Apache2::Const::OK;
			}
			else {
				return login_handler($r);
			}
		}
	}
	else {
		return login_handler($r);
	}	
}

sub login_handler {
	my $r = shift;
	
	my ($dbh, $sth, $d);
	$dbh = Nabovarme::Db->my_connect || die $!;

	my $cookie_token = unpack('H*', join('', map(chr(int Math::Random::Secure::rand(256)), 1..16)));

	my $passed_cookie = $r->headers_in->{Cookie} || '';
	my $passed_cookie_token;
	if ($passed_cookie) {
		($passed_cookie_token) = $passed_cookie =~ /auth_token=(.*)/;
	}
	warn Dumper $passed_cookie;
	my $cookie = CGI::Cookie->new(	-name  => 'auth_token',
								-value => $passed_cookie_token || $cookie_token,
								-expires => '+1y');

	my $quoted_passed_cookie_token = $dbh->quote($passed_cookie_token || $cookie_token);

	$sth = $dbh->prepare(qq[SELECT `auth_state` FROM sms_auth WHERE cookie_token LIKE $quoted_passed_cookie_token LIMIT 1]);
	$sth->execute;
	if ($d = $sth->fetchrow_hashref) {
		warn Dumper $d->{auth_state};
		if ($d->{auth_state} =~ /new/i) {			
			$dbh->do(qq[UPDATE sms_auth SET auth_state = 'login', unix_time = ] . time() . qq[ WHERE cookie_token = $quoted_passed_cookie_token]) or warn $!;
			
			$r->err_headers_out->add('Set-Cookie' => $cookie);
			#$r->internal_redirect("/private/login.epl");
			#return Apache2::Const::OK;
			$r->err_headers_out->add('Location' => "/private/login.epl");
			return Apache2::Const::REDIRECT;
		}
		elsif ($d->{auth_state} =~ /login/i) {
			# look up phone number
			my ($id) = $r->args =~ /id=([^&]*)/i;
			my $quoted_id = $dbh->quote($id);
			$sth = $dbh->prepare(qq[SELECT `sms_notification` FROM meters WHERE `sms_notification` LIKE $quoted_id LIMIT 1]);
			$sth->execute;
			if ($d = $sth->fetchrow_hashref) {
				# if user has a phone number in database generate and send sms code
				my $sms_code = join('', map(int(Math::Random::Secure::rand(9)), 1..6));
				my $quoted_sms_code = $dbh->quote($sms_code);
				$dbh->do(qq[UPDATE sms_auth SET `auth_state` = 'sms_code_sent', `sms_code` = $sms_code, unix_time = ] . time() . qq[ WHERE cookie_token = $quoted_passed_cookie_token]) or warn $!;
				
				sms_send($d->{sms_notification}, $sms_code);

				$r->err_headers_out->add('Set-Cookie' => $cookie);
				#$r->internal_redirect("/private/sms_code.epl");
				#return Apache2::Const::OK;
				$r->err_headers_out->add('Location' => "/private/sms_code.epl");
				return Apache2::Const::REDIRECT;
			}
			else {
				# ask for phone number
				$r->err_headers_out->add('Set-Cookie' => $cookie);
				$r->internal_redirect("/private/login.epl");
				return Apache2::Const::OK;
				#$r->err_headers_out->add('Location' => "/private/login.epl");
				#return Apache2::Const::REDIRECT;
			}
		}
		elsif ($d->{auth_state} =~ /sms_code_sent/i) {
			# check if user entered correct code
			my ($sms_code) = $r->args =~ /sms_code=([^&]*)/i;
			my $quoted_sms_code = $dbh->quote($sms_code);
			my ($stay_logged_in) = $r->args =~ /stay_logged_in=([^&]*)/i;
			warn Dumper $sms_code;
			$sth = $dbh->prepare(qq[SELECT `sms_code`, `orig_uri` FROM sms_auth WHERE `cookie_token` LIKE $quoted_passed_cookie_token AND `sms_code` LIKE $quoted_sms_code LIMIT 1]);
			$sth->execute;
			if ($d = $sth->fetchrow_hashref) {
				# if sms code matches the one in database
				$dbh->do(qq[UPDATE sms_auth SET `auth_state` = 'sms_code_verified', unix_time = ] . time() . qq[ WHERE cookie_token = $quoted_passed_cookie_token]) or warn $!;
				$r->err_headers_out->add('Set-Cookie' => $cookie);
				$r->err_headers_out->add('Location' => $d->{orig_uri});
				return Apache2::Const::REDIRECT;
			}
			else {
				$r->err_headers_out->add('Set-Cookie' => $cookie);
				$r->internal_redirect("/private/sms_code.epl");
				return Apache2::Const::OK;
				#$r->err_headers_out->add('Location' => "/private/sms_code.epl");
				#return Apache2::Const::REDIRECT;
			}
		
		}
		elsif ($d->{auth_state} =~ /sms_code_verified/i) {
			$r->err_headers_out->add('Set-Cookie' => $cookie);
			return Apache2::Const::OK;
		}
		elsif ($d->{auth_state} =~ /deny/i) {
			return login_handler($r);
		}
	}
	else {
		# send new cookie

		my $quoted_cookie_token = $dbh->quote($passed_cookie_token || $cookie_token);
		my $quoted_orig_uri = $dbh->quote($r->uri);
		$dbh->do(qq[INSERT INTO sms_auth (cookie_token, auth_state, orig_uri, unix_time) VALUES ($quoted_cookie_token, 'new', $quoted_orig_uri, ] . time() . qq[)]) or warn $!;

		$r->err_headers_out->add('Set-Cookie' => $cookie);

		# redirect to login page
#		$r->internal_redirect("/private/login.epl");
#		return Apache2::Const::OK;
		$r->err_headers_out->add('Location' => "/private/login.epl");
		return Apache2::Const::REDIRECT;
	}
}

sub logout_handler {
	my $r = shift;
	
	my ($dbh, $sth, $d);
	$dbh = Nabovarme::Db->my_connect || die $!;

	# remove cookie
	
	my $passed_cookie = $r->headers_in->{Cookie} || '';
	my $passed_cookie_token;
	if ($passed_cookie) {
		($passed_cookie_token) = $passed_cookie =~ /auth_token=(.*)/;
	}
	my $cookie = CGI::Cookie->new(	-name  => 'auth_token',
									-value => $passed_cookie_token,
									-expires => '-1y');
	warn Dumper $cookie;
	
	my $quoted_cookie_token = $dbh->quote($passed_cookie_token);
	$dbh->do(qq[DELETE FROM sms_auth WHERE cookie_token = $quoted_cookie_token]) or warn $!;
	
	$r->err_headers_out->add('Set-Cookie' => $cookie);
	
	# redirect to logged out page
	$r->err_headers_out->add('Location' => "/logged_out.epl");
	return Apache2::Const::REDIRECT;
}

sub sms_send {
	my ($destination, $message) = @_;
	$destination = '45' . $destination;
		
	# convert message from UTF-8 to UCS
	$message = encode('UCS-2BE', decode('UTF-8', $message));

	my ($fh, $temp_file) = tempfile();

	print $fh "To: " . $destination . "\n";
	print $fh "Alphabet: UCS\n";
	print $fh "\n";
	print $fh $message . "\n";

	move($temp_file, SMS_SPOOL_DIR . '/' . $destination . '_' . basename($temp_file)) || die $!;
}

1;

__END__
