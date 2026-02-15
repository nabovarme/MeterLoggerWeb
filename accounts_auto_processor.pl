#!/usr/bin/perl -w

use strict;
use Data::Dumper;
use Date::Language;
use Time::Local;
use Sys::Syslog;
use DBI;

use Nabovarme::Db;

$SIG{INT} = \&sig_int_handler;

openlog($0, "ndelay,pid", "local0");
syslog('info', "starting...");

my $dbh;
my $sth;
my $d;

my $amount;
my $phone;

# connect to db
if ($dbh = Nabovarme::Db->my_connect) {
	$dbh->{'mysql_auto_reconnect'} = 1;
	syslog('info', "connected to db");
}
else {
	syslog('info', "cant't connect to db $!");
	die $!;
}

while (1) {
	$sth = $dbh->prepare(qq[SELECT COUNT(*) FROM accounts_auto WHERE `state` = 'new']) || warn $!;
	$sth->execute || warn $!;
	my $count = $sth->fetchrow_array;
	
	$sth = $dbh->prepare(qq[SELECT `id`, `info_row`, `info_detail` FROM accounts_auto WHERE `state` = 'new']);
	$sth->execute || warn $!;
	
	while ($d = $sth->fetchrow_hashref) {
		# match a date in d.m.yyyy format
		if ($d->{info_row} =~ /(\d+)\.(\d+)\.(\d{4})/) {
			$dbh->do(qq[UPDATE accounts_auto SET payment_time = ] . timelocal(0, 0, 12, $1, $2 - 1, $3) . qq[ WHERE `id` = ] . $d->{id}) || warn $!;
		}
		else {
			warn "date does not match\n";
			$dbh->do(qq[UPDATE accounts_auto SET `state` = 'partially_parsed' WHERE `id` = ] . $d->{id}) || warn $!;
			next;
		}
		
		# match an amount
		if ($d->{info_row} =~ /received\s*mon.*?(\d*[\d\.]+\,\d{2})/is) {
			$amount = $1;
			$amount =~ s/\.//;		# no 1000 separator for mysql
			$amount =~ s/\,/\./;	# mysql uses . for decimal
			$dbh->do(qq[UPDATE accounts_auto SET amount = ] . $dbh->quote($amount) . qq[ WHERE `id` = ] . $d->{id}) || warn $!;
			$dbh->do(qq[UPDATE accounts_auto SET `state` = 'partially_parsed' WHERE `id` = ] . $d->{id}) || warn $!;
		}
		else {
			warn "amount does not match\n";
			$dbh->do(qq[UPDATE accounts_auto SET `state` = 'error' WHERE `id` = ] . $d->{id}) || warn $!;
			next;
		}

		# match phone number and look up serial
		if ($d->{info_detail} =~ /(\+\d+\s*)([\d\s]{8}[\d\s]*)/is) {
			$phone = $1 . $2;		# country prefix and phone
			$phone =~ s/\s+//sg;	# remove spaces in phone number
			$phone =~ s/\+45//s;	# remove danish phone prefix
			
			# save phone to db
			$dbh->do(qq[UPDATE accounts_auto SET `phone` = ] . $dbh->quote($phone) . qq[ WHERE `id` = ] . $d->{id}) || warn $!;

			# look up phone number in meters table
			my $sth_meters = $dbh->prepare(qq[SELECT `serial` FROM meters WHERE `sms_notification` LIKE '%] . $phone . qq[%']) || warn $!;
			$sth_meters->execute || warn $!;
			if (my $serial = $sth_meters->fetchrow_array) {
				if ($dbh->do(qq[UPDATE accounts_auto SET `serial` = ] . $dbh->quote($serial) . qq[ WHERE `id` = ] . $d->{id})) {
					$dbh->do(qq[UPDATE accounts_auto SET `state` = 'parsed' WHERE `id` = ] . $d->{id}) || warn $!;
				}
				else {
					# error updating
					$dbh->do(qq[UPDATE accounts_auto SET `state` = 'error' WHERE `id` = ] . $d->{id}) || warn $!;
				}
			}
			else {
				# not found in meters, try to lookup in accounts_auto_payers_learned
				my $sth_payers_learned = $dbh->prepare(qq[SELECT `serial` FROM accounts_auto_payers_learned WHERE phone like '%] . $phone . qq[%' LIMIT 1]) || warn $!;
				$sth_payers_learned->execute || warn $!;
				if (my $serial = $sth_payers_learned->fetchrow_array) {
					if ($dbh->do(qq[UPDATE accounts_auto SET `serial` = ] . $dbh->quote($serial) . qq[ WHERE `id` = ] . $d->{id})) {
						$dbh->do(qq[UPDATE accounts_auto SET `state` = 'parsed' WHERE `id` = ] . $d->{id}) || warn $!;
					}
					else {
						# error updating
						$dbh->do(qq[UPDATE accounts_auto SET `state` = 'error' WHERE `id` = ] . $d->{id}) || warn $!;
					}
				}
				else {
					warn "no serial for phone number found in db\n";
					warn Dumper $serial;
					warn Dumper $phone;
					$dbh->do(qq[UPDATE accounts_auto SET `state` = 'ignored' WHERE `id` = ] . $d->{id}) || warn $!;
				}
			}
		}
		else {
			warn "phone does not match\n";
			$dbh->do(qq[UPDATE accounts_auto SET `state` = 'partially_parsed' WHERE `id` = ] . $d->{id}) || warn $!;
			next;
		}
	}
	sleep 10;
}

# end of main

sub sig_int_handler {
	$sth->finish;
	$dbh->disconnect;
	die $!;
}

1;
__END__
