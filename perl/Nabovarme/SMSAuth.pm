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
use constant SNOOZE_LOCATION => '/snooze.epl';

use lib qw( /etc/apache2/perl );
use Nabovarme::Db;

# Main Apache request handler
sub handler {
	my $r = shift;

	my $logout_path = $r->dir_config('LogoutPath') || 'logout';
	my $logged_out_path = $r->dir_config('LoggedOutPath') || '/logged_out.epl';
	my $public_access = $r->dir_config('PublicAccess') || '';
	
	# Ignore specific URI paths
	if ($r->uri eq SNOOZE_LOCATION) {
		warn Dumper "snooze location, we dont handle this: " . $r->uri;
		return Apache2::Const::OK;
	}

	if ($public_access) {
		foreach (split(/,\s*/, $public_access)) {
			if ($r->uri eq $_) {
				warn Dumper "we dont handle this: " . $r->uri;
				return Apache2::Const::OK;
			}
		}
	}
	
	if ($r->uri eq $logged_out_path) {
		warn Dumper "we dont handle this: " . $r->uri;
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
	my $default_stay_logged_in = $r->dir_config('DefaultStayLoggedIn') || 'true';

	my ($dbh, $sth, $d);
	if ($dbh = Nabovarme::Db->my_connect) {

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
				my ($id) = $r->args =~ /id=([^&]*)/i;
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
					
					sms_send($id, "SMS Code: $sms_code");

					if ($default_stay_logged_in eq 'true') {
						# Persistent cookie
						$cookie = CGI::Cookie->new(
							-name    => 'auth_token',
							-value   => $cookie_token,
							-expires => '+1y'
						);
					} else {
						# Session cookie
						$cookie = CGI::Cookie->new(
							-name  => 'auth_token',
							-value => $cookie_token
						);
					}
					add_set_cookie_once($r, $cookie);
					$r->err_headers_out->add('Location' => $sms_code_path . ($default_stay_logged_in ? '?stay_logged_in=true' : ''));
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
				my ($sms_code) = $r->args =~ /sms_code=([^&]*)/i;
				my $quoted_sms_code = $dbh->quote($sms_code);
				my ($stay_logged_in) = $r->args =~ /stay_logged_in=([^&]*)/i;

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
					add_set_cookie_once($r, $cookie);
					$r->err_headers_out->add('Location' => $d->{orig_uri});
					return Apache2::Const::REDIRECT;
				} else {
					# Invalid code, reload SMS form
					add_set_cookie_once($r, $cookie);
					$r->internal_redirect($sms_code_path . '?' . $r->args);
					return Apache2::Const::OK;
				}
			}
			elsif ($d->{auth_state} =~ /sms_code_verified/i) {
				# User is authenticated; possibly use session cookie
				$sth = $dbh->prepare(qq[SELECT `session` FROM sms_auth WHERE `cookie_token` LIKE $quoted_passed_cookie_token LIMIT 1]);
				$sth->execute;
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
		
		my $quoted_cookie_token = $dbh->quote($passed_cookie_token);
		$dbh->do(qq[DELETE FROM sms_auth WHERE cookie_token = $quoted_cookie_token]) or warn $!;
		
		add_set_cookie_once($r, $cookie);
		$r->internal_redirect($logged_out_path);
		return Apache2::Const::OK;
	}

	$r->err_headers_out->set('Retry-After' => '60');
	return Apache2::Const::HTTP_SERVICE_UNAVAILABLE;
}

# Sends SMS message via local SMTP relay
sub sms_send {
	my ($destination, $message) = @_;
	$destination = '45' . $destination;

	my $smtp = Net::SMTP->new('postfix');	
		
	$smtp->mail('meterlogger');
	if ($smtp->to($destination . '@meterlogger')) {
		$smtp->data();
		$smtp->datasend("$message");
		$smtp->dataend();
	} else {
		print "Error: ", $smtp->message();
	}

	$smtp->quit;
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

1;

__END__
