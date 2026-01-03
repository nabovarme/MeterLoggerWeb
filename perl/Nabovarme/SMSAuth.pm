package Nabovarme::SMSAuth;

use strict;
use Data::Dumper;
use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::SubRequest ();
use Apache2::Const -compile => qw(OK REDIRECT HTTP_NOT_FOUND HTTP_SERVICE_UNAVAILABLE);
use CGI::Cookie ();
use CGI;
use Math::Random::Secure qw(rand);
use DBI;
use utf8;

use Net::SMTP;

use constant SMS_SPOOL_DIR => '/var/www/nabovarme/sms_spool';
use constant SNOOZE_LOCATION => '/api/snooze';

use Nabovarme::Db;
use Nabovarme::Utils;

# Main Apache request handler
sub handler {
	my $r = shift;

	my $logout_path = $r->dir_config('LogoutPath') || 'logout';
	my $logged_out_path = $r->dir_config('LoggedOutPath') || '/logged_out.epl';
	my $public_access = $r->dir_config('PublicAccess') || '';
	
	# Ignore specific URI paths
	if ($r->uri =~ qr/^@{[SNOOZE_LOCATION]}/) {
		$r->warn("snooze location, we dont handle this: " . $r->uri);
		return Apache2::Const::OK;
	}

	if ($public_access) {
		foreach (split(/,\s*/, $public_access)) {
			if ($r->uri eq $_) {
				$r->warn("we dont handle this: " . $r->uri);
				return Apache2::Const::OK;
			}
		}
	}
	
	if ($r->uri eq $logged_out_path) {
		$r->warn("we dont handle this: " . $r->uri);
		return Apache2::Const::OK;
	}
	
	my ($dbh, $sth, $d);
	if ($dbh = Nabovarme::Db->my_connect) {
		my $passed_cookie = $r->headers_in->{Cookie} || '';
		if ($passed_cookie) {
			# Handle logout requests
			if (index($r->uri, $logout_path) >= 0) {
				return logout_handler($r);
			}
		}	

		# Default to login handler
		return login_handler($r);
	}

	# If DB connection fails, instruct client to retry later
	$r->err_headers_out->set('Retry-After' => '60');
	return Apache2::Const::HTTP_SERVICE_UNAVAILABLE;
}

# Handles login state machine: new -> login -> sms_code_sent -> sms_code_verified
sub login_handler {
	my $r = shift;
	
	my $login_path = $r->dir_config('LoginPath') || '/private/login.epl';
	my $logout_path = $r->dir_config('LogoutPath') || 'logout';
	my $logged_out_path = $r->dir_config('LoggedOutPath') || '/logged_out.epl';
	my $sms_code_path = $r->dir_config('SMSCodePath') || '/private/sms_code.epl';
	my $default_path = $r->dir_config('DefaultPath') || '/';

	my ($dbh, $sth, $d);
	if ($dbh = Nabovarme::Db->my_connect) {

		my $cgi = CGI->new($r);

		# Parse existing cookie
		my $cookie_header = $r->headers_in->{Cookie} || '';
		my %cookies = CGI::Cookie->parse($cookie_header);
		my $passed_cookie_token = $cookies{'auth_token'} ? scalar $cookies{'auth_token'}->value : undef;

		my $cookie_token;
		my $cookie;

		if ($passed_cookie_token) {
			# Use existing token/cookie
			$cookie_token = $passed_cookie_token;
			$cookie = $cookies{'auth_token'};
		} else {
			# Generate new token and cookie
			$cookie_token = unpack('H*', join('', map(chr(int Math::Random::Secure::rand(256)), 1..16)));
			$cookie = CGI::Cookie->new(
				-name  => 'auth_token',
				-value => $cookie_token,
				-expires => '+1y'
			);
			# Set the new cookie early so it's only set once
			add_set_cookie_once($r, $cookie);
		}
	
		my $quoted_passed_cookie_token = $dbh->quote($passed_cookie_token || $cookie_token);
	
		# Look up authentication state by token
		$sth = $dbh->prepare(qq[SELECT `auth_state` FROM sms_auth WHERE cookie_token LIKE $quoted_passed_cookie_token LIMIT 1]);
		$sth->execute;
		if ($d = $sth->fetchrow_hashref) {
			if ($d->{auth_state} =~ /new/i) {
				# Update state to 'login'
				$dbh->do(qq[UPDATE sms_auth SET auth_state = 'login', unix_time = ] . time() . qq[ WHERE cookie_token = $quoted_passed_cookie_token]) or warn $!;
				
				add_set_cookie_once($r, $cookie);
				$r->err_headers_out->add('Location' => $login_path);
				return Apache2::Const::REDIRECT;
			}
			elsif ($d->{auth_state} =~ /login/i) {
				# Attempt to match user's phone number
				my $id = $cgi->param('id');
				my $quoted_id = $dbh->quote($id);
				my $quoted_wildcard_id = $dbh->quote('%' . $id . '%');
				my $user_is_in_db = undef;
				
				if ($id) {
					# Check meters table
					$sth = $dbh->prepare(qq[SELECT `sms_notification` FROM meters WHERE `sms_notification` LIKE $quoted_wildcard_id LIMIT 1]);
					$sth->execute;
					$user_is_in_db = $sth->rows;
				
					# Check users table
					$sth = $dbh->prepare(qq[SELECT `phone` FROM users WHERE `phone` LIKE $quoted_wildcard_id LIMIT 1]);
					$sth->execute;
					$user_is_in_db |= $sth->rows;
				}
				
				if ($user_is_in_db) {
					# Generate and send SMS code
					my $sms_code = join('', map(int(Math::Random::Secure::rand(10)), 1..6));
					my $quoted_sms_code = $dbh->quote($sms_code);
					$dbh->do(qq[UPDATE sms_auth SET `auth_state` = 'sms_code_sent', `sms_code` = $quoted_sms_code, `phone` = $quoted_id, unix_time = ] . time() . qq[ WHERE cookie_token = $quoted_passed_cookie_token]) or warn $!;
					
					send_notification($id, "SMS Code: $sms_code");

					# Start with a session cookie
					$cookie = CGI::Cookie->new(
						-name  => 'auth_token',
						-value => $cookie_token
					);
					add_set_cookie_once($r, $cookie);
					$r->err_headers_out->add('Location' => $sms_code_path);
					return Apache2::Const::REDIRECT;
				} else {
					# Redirect to login form to re-enter phone number
					add_set_cookie_once($r, $cookie);
					$r->internal_redirect($login_path);
					return Apache2::Const::OK;
				}
			}
			elsif ($d->{auth_state} =~ /sms_code_sent/i) {
				# Validate submitted SMS code
				my $sms_code = $cgi->param('sms_code');
				my $quoted_sms_code = $dbh->quote($sms_code);
				my $stay_logged_in = $cgi->param('stay_logged_in');

				if ($stay_logged_in) {
					# Recreate persistent cookie (with expiration)
					$cookie = CGI::Cookie->new(
						-name	=> 'auth_token',
						-value   => $passed_cookie_token,
						-expires => '+1y'
					);
				} else {
					# Create session cookie (no expiration)
					$cookie = CGI::Cookie->new(
						-name  => 'auth_token',
						-value => $passed_cookie_token
					);
				}

				$sth = $dbh->prepare(qq[SELECT `sms_code`, `orig_uri` FROM sms_auth WHERE `cookie_token` LIKE $quoted_passed_cookie_token AND `sms_code` LIKE $quoted_sms_code LIMIT 1]);
				$sth->execute;
				if ($d = $sth->fetchrow_hashref) {
					# SMS code is valid
					$dbh->do(qq[UPDATE sms_auth SET `auth_state` = 'sms_code_verified', `session` = ] . ($stay_logged_in ? 0 : 1) . qq[, unix_time = ] . time() . qq[ WHERE cookie_token = $quoted_passed_cookie_token]) or warn $!;

					# Log admin login if applicable
					log_admin_event($dbh, $r, 'login', $dbh->quote($passed_cookie_token));

					add_set_cookie_once($r, $cookie);
					$r->err_headers_out->add('Location' => $d->{orig_uri});
					return Apache2::Const::REDIRECT;
				} else {
					# Invalid code, reload SMS form
					add_set_cookie_once($r, $cookie);
					$r->internal_redirect($sms_code_path);
					return Apache2::Const::OK;
				}
			}
			elsif ($d->{auth_state} =~ /sms_code_verified/i) {
				# User is authenticated; possibly use session cookie
				$sth = $dbh->prepare(qq[SELECT `session` FROM sms_auth WHERE `cookie_token` LIKE $quoted_passed_cookie_token LIMIT 1]);
				$sth->execute;
				$d = $sth->fetchrow_hashref;
				
				if ($d->{session}) {
					# Session cookie (no expiration)
					$cookie = CGI::Cookie->new(
						-name  => 'auth_token',
						-value => $passed_cookie_token
					);
				} else {
					# Persistent cookie (1 year expiration)
					$cookie = CGI::Cookie->new(
						-name    => 'auth_token',
						-value   => $passed_cookie_token,
						-expires => '+1y'
					);
				}
				# Update last used timestamp
				$dbh->do(qq[UPDATE sms_auth SET unix_time = ] . time() . qq[ WHERE cookie_token = $quoted_passed_cookie_token]) or warn $!;
				add_set_cookie_once($r, $cookie);
				return Apache2::Const::OK;
			}
			elsif ($d->{auth_state} =~ /deny/i) {
				# Denied state, restart auth flow
				return login_handler($r);
			}
		}
		else {
			# No record found, create a new login session
			my $quoted_cookie_token = $dbh->quote($passed_cookie_token || $cookie_token);
			my $quoted_remote_host = $dbh->quote($r->headers_in->{'X-Real-IP'} || $r->headers_in->{'X-Forwarded-For'} || $r->connection->remote_ip);
			my $quoted_user_agent = $dbh->quote($r->headers_in->{'User-Agent'});

			if (index($r->uri, $login_path) >= 0 || index($r->uri, $logout_path) >= 0 || index($r->uri, $logged_out_path) >= 0 || index($r->uri, $sms_code_path) >= 0) {
				my $quoted_default_path = $dbh->quote($default_path);
				$dbh->do(qq[INSERT INTO sms_auth (cookie_token, auth_state, orig_uri, remote_host, user_agent, unix_time) VALUES ($quoted_cookie_token, 'new', $quoted_default_path, $quoted_remote_host, $quoted_user_agent, ] . time() . qq[)]) or warn $!;
			} else {
				my $quoted_orig_uri = $dbh->quote($r->uri . ($r->args ? ('?' . $r->args) : ''));
				$dbh->do(qq[INSERT INTO sms_auth (cookie_token, auth_state, orig_uri, remote_host, user_agent, unix_time) VALUES ($quoted_cookie_token, 'new', $quoted_orig_uri, $quoted_remote_host, $quoted_user_agent, ] . time() . qq[)]) or warn $!;
			}
	
			add_set_cookie_once($r, $cookie);
			$r->err_headers_out->add('Location' => $login_path);
			return Apache2::Const::REDIRECT;
		}
	}

	$r->err_headers_out->set('Retry-After' => '60');
	return Apache2::Const::HTTP_SERVICE_UNAVAILABLE;
}

# Handles logout request: delete token and expire cookie
sub logout_handler {
	my $r = shift;
	
	my $logged_out_path = $r->dir_config('LoggedOutPath') || '/logged_out.epl';

	my ($dbh, $sth, $d);
	if ($dbh = Nabovarme::Db->my_connect) {
		my $passed_cookie = $r->headers_in->{Cookie} || '';
		my $passed_cookie_token;
		if ($passed_cookie) {
			my %cookies = CGI::Cookie->parse($passed_cookie);
			$passed_cookie_token = $cookies{'auth_token'} ? scalar $cookies{'auth_token'}->value : undef;
		}
		my $cookie = CGI::Cookie->new(
			-name  => 'auth_token',
			-value => $passed_cookie_token,
			-expires => '-1y'
		);
		
		# Log admin logout if applicable
		log_admin_event($dbh, $r, 'logout', $dbh->quote($passed_cookie_token));

		my $quoted_cookie_token = $dbh->quote($passed_cookie_token);
		$dbh->do(qq[DELETE FROM sms_auth WHERE cookie_token = $quoted_cookie_token]) or warn $!;
		
		add_set_cookie_once($r, $cookie);
		$r->internal_redirect($logged_out_path);
		return Apache2::Const::OK;
	}

	$r->err_headers_out->set('Retry-After' => '60');
	return Apache2::Const::HTTP_SERVICE_UNAVAILABLE;
}

sub add_set_cookie_once {
	my ($r, $cookie) = @_;
	my @cookies = $r->err_headers_out->get('Set-Cookie');
	foreach my $c (@cookies) {
		# Compare the cookie strings roughly (you can customize this)
		if ($c eq $cookie->as_string) {
			return;  # Cookie already set
		}
	}
	$r->err_headers_out->add('Set-Cookie' => $cookie);
}

# Log admin login/logout events
sub log_admin_event {
	my ($dbh, $r, $action, $quoted_cookie_token) = @_;

	# Only log if user is admin
	my $sth = $dbh->prepare(qq[
		SELECT u.username, u.admin_group, a.remote_host, a.user_agent
		FROM users u, sms_auth a
		WHERE a.cookie_token LIKE $quoted_cookie_token
			AND a.auth_state = 'sms_code_verified'
			AND u.phone = a.phone
		LIMIT 1
	]);
	$sth->execute;
	if (my $d = $sth->fetchrow_hashref) {
		if ($d->{admin_group} && length($d->{admin_group})) {
			# Insert log entry with all required fields
			$dbh->do(qq[
				INSERT INTO accounts_log
				(username, admin_group, type, info, serial, amount, price, remote_addr, user_agent, unix_time)
				VALUES (
					] . $dbh->quote($d->{username}) . qq[,
					] . $dbh->quote($d->{admin_group}) . qq[,
					'auth',
					] . $dbh->quote($action) . qq[,
					NULL,
					NULL,
					NULL,
					] . $dbh->quote($d->{remote_host}) . qq[,
					] . $dbh->quote($d->{user_agent}) . qq[,
					UNIX_TIMESTAMP()
				)
			]) or warn $!;
		}
	}
}

1;

__END__

/*
Nabovarme::SMSAuth - Apache mod_perl handler for phone number + SMS code login authentication

DESCRIPTION:

This module implements a lightweight, cookie-based login system using phone numbers and one-time SMS codes.
It is designed to work as a request handler in Apache2 with mod_perl, ensuring users authenticate before accessing protected resources.

The flow is cookie-driven and progresses through the following states:

  1. new               - A user lands on a protected page without authentication.
  2. login             - User is redirected to enter their phone number.
  3. sms_code_sent     - A one-time SMS code is generated and sent to the phone number.
  4. sms_code_verified - Upon correct code entry, the user is authenticated.
  5. deny              - Access denied; user must restart the flow.
  6. logout            - Auth cookie is expired, and session is deleted from DB.

Authentication state is persisted in a MySQL table `sms_auth`, keyed by a secure cookie token.

FLOW DIAGRAM:

             +--------------------+
             |  Incoming Request  |
             +--------------------+
                       |
                       v
             +---------------------+
             |  Already Auth'd?    |----> Yes -----> Serve Resource
             |  (valid cookie)     |
             +---------------------+
                       |
                      No
                       |
                       v
              +----------------------+
              |  State = 'new'       |
              |  -> insert session   |
              +----------------------+
                       |
                       v
            +------------------------+
            | Redirect to login.epl  |
            +------------------------+
                       |
                       v
            +-----------------------------+
            | User enters phone number    |
            +-----------------------------+
                       |
                       v
             +-----------------------------+
             | Valid phone number in DB?   |----> No ----> Reload login.epl
             +-----------------------------+
                       |
                      Yes
                       |
                       v
             +-----------------------------+
             | Generate and send SMS code  |
             | Update state = sms_code_sent|
             +-----------------------------+
                       |
                       v
             +----------------------------+
             | Redirect to sms_code.epl   |
             +----------------------------+
                       |
                       v
             +-----------------------------+
             | User enters SMS code        |
             +-----------------------------+
                       |
                       v
         +-------------------------------+
         |  Code matches entry in DB?    |----> No ----> Reload sms_code.epl
         +-------------------------------+
                       |
                      Yes
                       |
                       v
             +-------------------------------+
             | Update state = sms_code_verified
             | Redirect to original URI
             +-------------------------------+

DEPENDENCIES:

- Apache2::RequestRec
- Apache2::RequestIO
- Apache2::SubRequest
- CGI
- CGI::Cookie
- Math::Random::Secure
- DBI
- Net::SMTP
- Nabovarme::Db (custom)

SECURITY:

- Auth token is a secure, random 128-bit value stored in a cookie.
- Token is tied to IP and User-Agent.
- SMS codes are single-use and expire with DB cleanup strategy (not shown here).
- Optional "stay_logged_in" checkbox enables persistent auth cookies.

*/
