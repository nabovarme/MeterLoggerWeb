package Nabovarme::Admin;

use strict;
use warnings;
use DBI;
use Data::Dumper;
use Sys::Syslog;

use lib qw( /etc/apache2/perl );
#use lib qw( /opt/local/apache2/perl );
use Nabovarme::Db;

sub new {
	my $class = shift;

	my $self = {};
	$self->{dbh} = Nabovarme::Db->my_connect || die $!;

	return bless $self, $class;
}

sub cookie_is_admin {
	my ($self, $r, $serial) = @_;

	my $passed_cookie = $r->headers_in->{Cookie} || '';
	my $passed_cookie_token;
	if ($passed_cookie) {
		($passed_cookie_token) = $passed_cookie =~ /auth_token=(.*)/;
	}

	my ($sth, $d);
	my $quoted_passed_cookie_token = $self->{dbh}->quote($passed_cookie_token);

	$sth = $self->{dbh}->prepare(qq[SELECT `users`.username, `users`.admin_group FROM `users`, `sms_auth` \
			WHERE `sms_auth`.cookie_token LIKE $quoted_passed_cookie_token \
				AND `sms_auth`.auth_state = 'sms_code_verified' \
				AND `users`.phone = `sms_auth`.phone LIMIT 1]);

	$sth->execute;
	if ($d = $sth->fetchrow_hashref) {
		# user is admin
		my $username = $d->{username};
		my $admin_group = $d->{admin_group};

		my $quoted_serial = $self->{dbh}->quote($serial);

		# check which groups it is admin for
		$sth = $self->{dbh}->prepare(qq[SELECT `group` FROM `meters` WHERE `serial` LIKE $quoted_serial LIMIT 1]);
		$sth->execute;
		if ($d = $sth->fetchrow_hashref) {
			if (grep(/^$d->{group}$/, split(/,\s*/, $admin_group))) {
				warn "allowing $username as admin for group $admin_group, serial $serial\n";
				return 1;
			}
		}
	}
	warn "passed cookie $passed_cookie_token is not logged in as admin - go away!";
	return 0;
}

sub add {
	my ($self, $serial, $date, $info, $amount, $price) = @_;

	my ($quoted_serial, $quoted_unix_time, $quoted_info, $quoted_amount, $quoted_price);
	$quoted_serial = $self->{dbh}->quote($serial);
	$quoted_unix_time = $self->{dbh}->quote($date);
	$quoted_info = $self->{dbh}->quote($info);
	$quoted_amount = $self->{dbh}->quote($amount);
	$quoted_price = $self->{dbh}->quote($price);

	warn qq[INSERT INTO `accounts` (`payment_time`, `serial`, `info`, `amount`, `price`) VALUES ($quoted_unix_time, $quoted_serial, $quoted_info, $quoted_amount, $quoted_price)];
	$self->{dbh}->do(qq[INSERT INTO `accounts` (`payment_time`, `serial`, `info`, `amount`, `price`) VALUES ($quoted_unix_time, $quoted_serial, $quoted_info, $quoted_amount, $quoted_price)]) || die $!;
}

sub default_price_for_serial {
	my ($self, $serial) = @_;

	my ($quoted_serial);
	$quoted_serial = $self->{dbh}->quote($serial);


	my $sth = $self->{dbh}->prepare(qq[SELECT `default_price` FROM `meters` WHERE `serial` LIKE $quoted_serial LIMIT 1]);
	$sth->execute;
	if (my $d = $sth->fetchrow_hashref) {
		# get default price for meter
		return $d->{default_price};
	}
}

1;

