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

use Exporter 'import';
our @EXPORT_OK = qw(normalize_amount);

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
		($passed_cookie_token) = $passed_cookie =~ /auth_token=([^;]+)/;
	}

	my ($sth, $d);
	my $quoted_passed_cookie_token = $self->{dbh}->quote($passed_cookie_token);

	$sth = $self->{dbh}->prepare(qq[
		SELECT `users`.username, `users`.admin_group FROM `users`, `sms_auth`
			WHERE `sms_auth`.cookie_token LIKE $quoted_passed_cookie_token
				AND `sms_auth`.auth_state = 'sms_code_verified'
				AND `users`.phone = `sms_auth`.phone LIMIT 1
	]);

	$sth->execute;
	if ($d = $sth->fetchrow_hashref) {
		# user is admin
		my $username		= $d->{username};
		my $admin_group		= $d->{admin_group};

		my $quoted_serial = $self->{dbh}->quote($serial);

		# check which groups it is admin for
		$sth = $self->{dbh}->prepare(qq[
			SELECT `group` FROM `meters` WHERE `serial` LIKE $quoted_serial LIMIT 1
		]);
		$sth->execute;
		if ($d = $sth->fetchrow_hashref) {
			if (grep(/^$d->{group}$/, split(/,\s*/, $admin_group))) {

				# capture the real client IP behind proxy
				$self->{remote_addr} = $r->headers_in->{'X-Real-IP'}
				                     || $r->headers_in->{'X-Forwarded-For'}
				                     || $r->connection->remote_ip;

				$self->{user_agent} = $r->headers_in->{'User-Agent'};

				warn $ENV{REMOTE_ADDR} . " \"" . $r->method() . " " . $r->uri() . "\" \"" .
					$r->headers_in->{'User-Agent'} .
					"\" allowing $username as admin for group $admin_group, serial $serial\n";
				return 1;
			}
		}
	}
	warn $ENV{REMOTE_ADDR} . " \"" . $r->method() . " " . $r->uri() . "\" \"" .
		$r->headers_in->{'User-Agent'} .
		"\" passed cookie $passed_cookie_token is not logged in as admin - go away!";
	return 0;
}

sub add_payment {
	my ($self, $serial, $type, $date, $info, $amount, $price) = @_;

	# helper function to parse amount from user input
	my $norm_amount	= normalize_amount($amount);
	my $norm_price	= normalize_amount($price);

	my ($quoted_serial, $quoted_type, $quoted_unix_time, $quoted_info, $quoted_amount, $quoted_price);
	$quoted_serial		= $self->{dbh}->quote($serial);
	$quoted_type		= $self->{dbh}->quote($type);
	$quoted_unix_time	= $self->{dbh}->quote($date);
	$quoted_info		= $self->{dbh}->quote($info);
	$quoted_amount		= $self->{dbh}->quote($norm_amount);
	$quoted_price		= $self->{dbh}->quote($norm_price);

	# quoted audit fields
	my $quoted_user		= $self->{dbh}->quote($self->{username});
	my $quoted_group	= $self->{dbh}->quote($self->{admin_group});
	my $quoted_ip		= $self->{dbh}->quote($self->{remote_addr});
	my $quoted_ua		= $self->{dbh}->quote($self->{user_agent});

	# start transaction
	$self->{dbh}->{AutoCommit} = 0;

	eval {
		# insert payment
		warn qq[
			INSERT INTO `accounts`
			(`payment_time`, `serial`, `type`, `info`, `amount`, `price`)
			VALUES ($quoted_unix_time, $quoted_serial, $quoted_type, $quoted_info, $quoted_amount, $quoted_price)
		];

		$self->{dbh}->do(qq[
			INSERT INTO `accounts`
			(`payment_time`, `serial`, `type`, `info`, `amount`, `price`)
			VALUES ($quoted_unix_time, $quoted_serial, $quoted_type, $quoted_info, $quoted_amount, $quoted_price)
		]);

		# audit log (append-only, unix_time defaults to current UNIX timestamp)
		$self->{dbh}->do(qq[
			INSERT INTO `accounts_log`
			(`username`, `admin_group`, `serial`, `type`, `info`,
			 `amount`, `price`, `remote_addr`, `user_agent`)
			VALUES ($quoted_user, $quoted_group, $quoted_serial, $quoted_type,
			 $quoted_info, $quoted_amount, $quoted_price, $quoted_ip, $quoted_ua)
		]);

		$self->{dbh}->commit;
	};

	if ($@) {
		$self->{dbh}->rollback;
		$self->{dbh}->{AutoCommit} = 1;
		die "add_payment transaction failed: $@";
	}

	$self->{dbh}->{AutoCommit} = 1;
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

# helper function to parse amount from user input
sub normalize_amount {
	my ($input) = @_;

	# Remove spaces
	$input =~ s/\s+//g;

	# Handle comma as decimal separator (EU format)
	if ($input =~ /,\d{1,2}$/) {
		# Remove all dots (assumed as thousands separator)
		$input =~ s/\.//g;
		# Replace comma with dot
		$input =~ s/,/./;
	} else {
		# Remove all commas (assumed as thousands separator)
		$input =~ s/,//g;
	}

	# Now format to 2 decimal places
	return sprintf("%.2f", $input + 0);
}

1;

