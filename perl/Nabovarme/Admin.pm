package Nabovarme::Admin;

use strict;
use warnings;
use DBI;
use Sys::Syslog;

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

sub cookie_is_admin_for_serial {
	my ($self, $r, $serial) = @_;

	# capture the real client IP behind proxy once
	$self->{remote_addr} = $r->headers_in->{'X-Real-IP'}
	                     || $r->headers_in->{'X-Forwarded-For'}
	                     || $r->connection->remote_ip;

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

				$self->{user_agent} = $r->headers_in->{'User-Agent'};

				# store authenticated admin context
				$self->{username}    = $username;
				$self->{admin_group} = $admin_group;

				warn $self->{remote_addr} . " \"" . $r->method() . " " . $r->uri() . "\" \"" .
					$r->headers_in->{'User-Agent'} .
					"\" allowing $username as admin for group $admin_group, serial $serial\n";

				return 1;
			}
		}
	}

	# failed admin check
	$self->{user_agent} = $r->headers_in->{'User-Agent'};

	warn $self->{remote_addr} . " \"" . $r->method() . " " . $r->uri() . "\" \"" .
		$r->headers_in->{'User-Agent'} .
		"\" passed cookie $passed_cookie_token is not logged in as admin - go away!";

	return 0;
}

sub group_serials_by_cookie {
	my ($self, $r) = @_;

	# Step 0: Get verified phones for this cookie
	my $passed_cookie = $r->headers_in->{Cookie} || '';
	my ($passed_cookie_token) = $passed_cookie =~ /auth_token=([^;]+)/
		if $passed_cookie;

	unless ($passed_cookie_token) {
		warn "group_serials_by_cookie: no auth_token in Cookie header";
		return ();
	}

	my $sth_phones = $self->{dbh}->prepare(qq[
		SELECT phone
		FROM sms_auth
		WHERE cookie_token = ?
			AND auth_state = 'sms_code_verified'
			AND phone IS NOT NULL
			AND phone != ''
		ORDER BY unix_time DESC
		LIMIT 1;
	]);
	$sth_phones->execute($passed_cookie_token);

	my @phones;
	while (my $row = $sth_phones->fetchrow_hashref) {
		push @phones, $row->{phone};
	}
	warn "group_serials_by_cookie: verified phones = " . join(', ', @phones);

	return () unless @phones;

	# Step 1: Serial set 1 – match meters.sms_notification
	my $sth_meters = $self->{dbh}->prepare(qq[
		SELECT serial, sms_notification, `group`
		FROM meters
		WHERE sms_notification IS NOT NULL
		  AND sms_notification != ''
	]);
	$sth_meters->execute();

	my @serials_set1;
	while (my $row = $sth_meters->fetchrow_hashref) {
		my @notified_phones = map { s/^\s+|\s+$//gr } split /,/, $row->{sms_notification};
		if (grep { my $p = $_; grep { $_ eq $p } @phones } @notified_phones) {
			push @serials_set1, $row->{serial};
		}
	}
	warn "group_serials_by_cookie: serials_set1 = " . join(', ', @serials_set1);

	# Step 2: Serial set 2 – match meters.group via users.admin_group
	my %allowed_groups;
	my $sth_users = $self->{dbh}->prepare(qq[
		SELECT admin_group
		FROM users
		WHERE phone = ?
		  AND admin_group IS NOT NULL
		  AND admin_group != ''
	]);

	for my $phone (@phones) {
		$sth_users->execute($phone);
		while (my $row = $sth_users->fetchrow_hashref) {
			my @groups = split /\s*,\s*/, $row->{admin_group};
			$allowed_groups{$_} = 1 for @groups;
		}
	}
	warn "group_serials_by_cookie: allowed_groups = " . join(', ', sort keys %allowed_groups);

	my @serials_set2;
	my $sth_all_meters = $self->{dbh}->prepare(qq[
		SELECT serial, `group`
		FROM meters
	]);
	$sth_all_meters->execute();

	while (my $row = $sth_all_meters->fetchrow_hashref) {
		if ($allowed_groups{ $row->{group} }) {
			push @serials_set2, $row->{serial};
		}
	}
	warn "group_serials_by_cookie: serials_set2 = " . join(', ', @serials_set2);

	# Step 3: Merge and deduplicate
	my %seen;
	my @all_serials = grep { !$seen{$_}++ } (@serials_set1, @serials_set2);
	warn "group_serials_by_cookie: all_serials = " . join(', ', @all_serials);

	return @all_serials;
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

