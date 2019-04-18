package Nabovarme::Admin;

use strict;
use warnings;
use DBI;
use Data::Dumper;
use Sys::Syslog;

use lib qw( /etc/apache2/perl );
#use lib qw( /opt/local/apache2/perl );
use Nabovarme::Db;
use Nabovarme::MQTT_RPC;

sub new {
	my $class = shift;

	my $self = {};
	$self->{dbh} = Nabovarme::Db->my_connect || die $!;
	
	$self->{mqtt_rpc} = new Nabovarme::MQTT_RPC;
	$self->{mqtt_rpc}->connect() || die $!;

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
				warn $ENV{REMOTE_ADDR} . " \"" . $r->method() . " " . $r->uri() . "\" \"" . $r->headers_in->{'User-Agent'} . 
					"\" allowing $username as admin for group $admin_group, serial $serial\n";
				return 1;
			}
		}
	}
	warn $ENV{REMOTE_ADDR} . " \"" . $r->method() . " " . $r->uri() . "\" \"" . $r->headers_in->{'User-Agent'} . 
		"\" passed cookie $passed_cookie_token is not logged in as admin - go away!";
	return 0;
}

sub add_payment {
	my ($self, $serial, $type, $date, $info, $amount, $price) = @_;

	my ($quoted_serial, $quoted_type, $quoted_unix_time, $quoted_info, $quoted_amount, $quoted_price);
	$quoted_serial = $self->{dbh}->quote($serial);
	$quoted_type = $self->{dbh}->quote($type);
	$quoted_unix_time = $self->{dbh}->quote($date);
	$quoted_info = $self->{dbh}->quote($info);
	$quoted_amount = $self->{dbh}->quote($amount);
	$quoted_price = $self->{dbh}->quote($price);

	warn qq[INSERT INTO `accounts` (`payment_time`, `serial`, `type`, `info`, `amount`, `price`) VALUES ($quoted_unix_time, $quoted_serial, $quoted_type, $quoted_info, $quoted_amount, $quoted_price)];
	$self->{dbh}->do(qq[INSERT INTO `accounts` (`payment_time`, `serial`, `type`, `info`, `amount`, `price`) VALUES ($quoted_unix_time, $quoted_serial, $quoted_type, $quoted_info, $quoted_amount, $quoted_price)]) || die $!;
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

sub meter_change_valve_status {
	my ($self, $serial, $status) = @_;

	warn "\n\tChanged valve status for serial: " . $serial . " to " . $status . "\n\n";

	$self->{mqtt_rpc}->call({	serial => $serial,
							function => $status,
							param => '1',
							callback => undef,
							timeout => undef
						});

	$self->{mqtt_rpc}->call({	serial => $serial,
							function => 'status',
							param => '1',
							callback => undef,
							timeout => undef
						});
}

1;

