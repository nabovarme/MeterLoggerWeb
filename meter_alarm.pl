#!/usr/bin/perl -w

use strict;
use Data::Dumper;
use Sys::Syslog;
use DBI;
use Statistics::Basic qw( :all );
use Config;

use lib qw( /etc/apache2/perl );
use lib qw( /opt/local/apache2/perl/ );
use Nabovarme::Db;

openlog($0, "ndelay,pid", "local0");
syslog('info', "starting...");

# connect to db
my $dbh;
if ($dbh = Nabovarme::Db->my_connect) {
	$dbh->{'mysql_auto_reconnect'} = 1;
	syslog('info', "connected to db");
}
else {
	syslog('info', "cant't connect to db $!");
	die $!;
}

check_conditions();

# end of main

sub check_conditions {
	my $sth = $dbh->prepare(qq[SELECT `serial`, `condition`, `repeat`, `sms_notification`, `down_message`, `up_message` FROM `alarms`]);
	$sth->execute;
	if ($sth->rows) {
		my $serial;
		my $quoted_serial;
		my $condition;
		my $condition_var;
		my @condition_vars;
		my $d;
		while ($d = $sth->fetchrow_hashref) {
			# check every alarm in database
			$condition = $d->{condition};
			$serial = $d->{serial};
			@condition_vars = ($condition =~ /\$(\w+)/g);
			if (scalar(@condition_vars) == 0) {
				@condition_vars = ();
			}
			else {
				# we need to look up median value for passed condition variables
				for $condition_var (@condition_vars) {
					my $quoted_condition_var = '`' . $condition_var . '`';
					$quoted_serial = $dbh->quote($serial);
					my $values = [];
					my $median;
					my $sth_condition_vars = $dbh->prepare(qq[SELECT ] . $quoted_condition_var . qq[ FROM `samples` \
																WHERE `serial` like ] . $quoted_serial . qq[ ORDER BY `unix_time` DESC LIMIT 3]);
					$sth_condition_vars->execute;
					if ($sth_condition_vars->rows) {
						$values = $sth_condition_vars->fetchall_arrayref;
						$median = median(@$values) + 0.0;	# hack to convert , to .
						$condition =~ s/\$$condition_var/$median/x;
					}
				}				
			}
			$dbh->do(qq[UPDATE alarms SET \
							last_checked = ] . time() . qq[ \
							WHERE `serial` like $quoted_serial]) or warn $!;
			
			print Dumper $condition;
			if (eval $condition) {
				print "true\n";
			}
			else {
				print "false\n";
			}
		}
	}
}



__END__
