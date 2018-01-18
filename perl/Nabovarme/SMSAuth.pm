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
	}	

	return login_handler($r);
}

sub login_handler {
	my $r = shift;
	
	my $login_path = $r->dir_config('LoginPath') || '/private/login.epl';
	my $logged_out_path = $r->dir_config('LoggedOutPath') || '/logged_out.epl';
	my $sms_code_path = $r->dir_config('SMSCodePath') || '/private/sms_code.epl';
	my $default_path = $r->dir_config('DefaultPath') || '/';
	my $default_stay_logged_in = $r->dir_config('DefaultStayLoggedIn') || 'true';

	my ($dbh, $sth, $d);
	$dbh = Nabovarme::Db->my_connect || die $!;

	my $cookie_token = unpack('H*', join('', map(chr(int Math::Random::Secure::rand(256)), 1..16)));

	my $passed_cookie = $r->headers_in->{Cookie} || '';
	my $passed_cookie_token;
	if ($passed_cookie) {
		($passed_cookie_token) = $passed_cookie =~ /auth_token=(.*)/;
	}
#	warn Dumper $passed_cookie;
	my $cookie = CGI::Cookie->new(	-name  => 'auth_token',
								-value => $passed_cookie_token || $cookie_token,
								-expires => '+1y');

	my $quoted_passed_cookie_token = $dbh->quote($passed_cookie_token || $cookie_token);

	$sth = $dbh->prepare(qq[SELECT `auth_state` FROM sms_auth WHERE cookie_token LIKE $quoted_passed_cookie_token LIMIT 1]);
	$sth->execute;
	if ($d = $sth->fetchrow_hashref) {
#		warn Dumper $d->{auth_state};
		if ($d->{auth_state} =~ /new/i) {			
			$dbh->do(qq[UPDATE sms_auth SET auth_state = 'login', unix_time = ] . time() . qq[ WHERE cookie_token = $quoted_passed_cookie_token]) or warn $!;
			
			$r->err_headers_out->add('Set-Cookie' => $cookie);
			#$r->internal_redirect("/private/login.epl");
			#return Apache2::Const::OK;
			$r->err_headers_out->add('Location' => $login_path);
			return Apache2::Const::REDIRECT;
		}
		elsif ($d->{auth_state} =~ /login/i) {
			# look up phone number
			my ($id) = $r->args =~ /id=([^&]*)/i;
			my $quoted_id = $dbh->quote($id);
			
			# check in meters db
			$sth = $dbh->prepare(qq[SELECT `sms_notification` FROM meters WHERE `sms_notification` LIKE $quoted_id LIMIT 1]);
			$sth->execute;
			my $user_is_in_db = $sth->rows;
			
			# check in users db
			$sth = $dbh->prepare(qq[SELECT `phone` FROM users WHERE `phone` LIKE $quoted_id LIMIT 1]);
			$sth->execute;
			$user_is_in_db |= $sth->rows;
			
			if ($user_is_in_db) {
				# if user has a phone number in database generate and send sms code
				my $sms_code = join('', map(int(Math::Random::Secure::rand(9)), 1..6));
				my $quoted_sms_code = $dbh->quote($sms_code);
				$dbh->do(qq[UPDATE sms_auth SET `auth_state` = 'sms_code_sent', `sms_code` = $quoted_sms_code, `phone` = $quoted_id, unix_time = ] . time() . qq[ WHERE cookie_token = $quoted_passed_cookie_token]) or warn $!;
				
				sms_send($id, "SMS Code: $sms_code");

				$r->err_headers_out->add('Set-Cookie' => $cookie);
				#$r->internal_redirect("/private/sms_code.epl");
				#return Apache2::Const::OK;
				$r->err_headers_out->add('Location' => $sms_code_path . ($default_stay_logged_in ? '?stay_logged_in=true' : ''));
				return Apache2::Const::REDIRECT;
			}
			else {
				# ask for phone number
				$r->err_headers_out->add('Set-Cookie' => $cookie);
				$r->internal_redirect($login_path);
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
			unless ($stay_logged_in) {
				#$cookie->expires('');
				$cookie = CGI::Cookie->new(	-name  => 'auth_token',
											-value => $passed_cookie_token);
#				warn Dumper "session cookie";
#				warn Dumper $cookie;
			}
			$sth = $dbh->prepare(qq[SELECT `sms_code`, `orig_uri` FROM sms_auth WHERE `cookie_token` LIKE $quoted_passed_cookie_token AND `sms_code` LIKE $quoted_sms_code LIMIT 1]);
			$sth->execute;
			if ($d = $sth->fetchrow_hashref) {
				# if sms code matches the one in database
				if ($stay_logged_in) {
					$dbh->do(qq[UPDATE sms_auth SET `auth_state` = 'sms_code_verified', `session` = 0, unix_time = ] . time() . qq[ WHERE cookie_token = $quoted_passed_cookie_token]) or warn $!;
				}
				else {
					$dbh->do(qq[UPDATE sms_auth SET `auth_state` = 'sms_code_verified', `session` = 1, unix_time = ] . time() . qq[ WHERE cookie_token = $quoted_passed_cookie_token]) or warn $!;
				}
				$r->err_headers_out->add('Set-Cookie' => $cookie);
				$r->err_headers_out->add('Location' => $d->{orig_uri});
				return Apache2::Const::REDIRECT;
			}
			else {
				# let user retry
				$r->err_headers_out->add('Set-Cookie' => $cookie);
				$r->internal_redirect($sms_code_path . '?' . $r->args);	# add args for embperl on the page
				return Apache2::Const::OK;
				#$r->err_headers_out->add('Location' => "/private/sms_code.epl");
				#return Apache2::Const::REDIRECT;
			}
		
		}
		elsif ($d->{auth_state} =~ /sms_code_verified/i) {
			# if db says its a session cookie send session cookie
			$sth = $dbh->prepare(qq[SELECT `session` FROM sms_auth WHERE `cookie_token` LIKE $quoted_passed_cookie_token LIMIT 1]);
			$sth->execute;
			if ($d = $sth->fetchrow_hashref) {
				if ($d->{session}) {
					$cookie = CGI::Cookie->new(	-name  => 'auth_token',
												-value => $passed_cookie_token);
				}
			}
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
		if (index($r->uri, $login_path) || index($r->uri, $logged_out_path) || index($r->uri, $sms_code_path)) {
			# if the requested url is a special one, go to default path
			my $quoted_default_path = $dbh->quote($default_path);
			$dbh->do(qq[INSERT INTO sms_auth (cookie_token, auth_state, orig_uri, unix_time) VALUES ($quoted_cookie_token, 'new', $quoted_default_path, ] . time() . qq[)]) or warn $!;
		}
		else {
			my $quoted_orig_uri = $dbh->quote($r->uri . ($r->args ? ('?' . $r->args) : ''));
			$dbh->do(qq[INSERT INTO sms_auth (cookie_token, auth_state, orig_uri, unix_time) VALUES ($quoted_cookie_token, 'new', $quoted_orig_uri, ] . time() . qq[)]) or warn $!;
		}

		$r->err_headers_out->add('Set-Cookie' => $cookie);

		# redirect to login page
#		$r->internal_redirect("/private/login.epl");
#		return Apache2::Const::OK;
		$r->err_headers_out->add('Location' => $login_path);
		return Apache2::Const::REDIRECT;
	}
}

sub logout_handler {
	my $r = shift;
	
	my $logged_out_path = $r->dir_config('LoggedOutPath') || '/logged_out.epl';

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
#	warn Dumper $cookie;
	
	my $quoted_cookie_token = $dbh->quote($passed_cookie_token);
	$dbh->do(qq[DELETE FROM sms_auth WHERE cookie_token = $quoted_cookie_token]) or warn $!;
	
	$r->err_headers_out->add('Set-Cookie' => $cookie);
	
	# redirect to logged out page
	$r->internal_redirect($logged_out_path);
	return Apache2::Const::OK;
#	$r->err_headers_out->add('Location' => $logged_out_path);
#	return Apache2::Const::REDIRECT;
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
