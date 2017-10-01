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

while (1) {
	check_conditions();
	sleep 60;
}

# end of main

sub check_conditions {
	my $sth = $dbh->prepare(qq[SELECT `serial`, `condition`, `last_notification`, `alarm_state`, `repeat`, `sms_notification`, `down_message`, `up_message` FROM `alarms`]);
	$sth->execute;
	if ($sth->rows) {
		my $serial;
		my $quoted_serial;
		my $condition;
		my $condition_var;
		my @condition_vars;
		my $down_message;
		my $up_message;
		my $d;
		while ($d = $sth->fetchrow_hashref) {
			# check every alarm in database
			$condition = $d->{condition};
			$serial = $d->{serial};
			$down_message = $d->{down_message} || 'up';
			$up_message = $d->{up_message} || 'down';
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
						# replace symbol with value from database
						$condition =~ s/\$$condition_var/$median/x;
						$down_message =~ s/\$$condition_var/$median/x;
						$up_message =~ s/\$$condition_var/$median/x;
					}
				}				
			}
			
			syslog('info', "checking condition for serial $serial: $condition");
			warn "checking condition for serial $serial: $condition";
			if (eval $condition) {
				# condition met, an alarm should be sent if we not dit it in the latest repeat time interval
				if ($d->{alarm_state} == 0) {
					# changed from no alarm to alarm - send sms
					if ($d->{sms_notification}) {
						system(qq[gammu-smsd-inject EMS $d->{sms_notification} -unicode -text "$down_message"]);
						warn(qq[gammu-smsd-inject EMS $d->{sms_notification} -unicode -text "$down_message"]);
					}
					$dbh->do(qq[UPDATE alarms SET \
									last_notification = ] . time() . qq[, \
									alarm_state = 1 \
									WHERE `serial` like $quoted_serial]) or warn $!;
					syslog('info', "serial $serial: down");
					warn "down\n";
				}
				elsif ($d->{repeat} && (($d->{last_notification} + $d->{repeat}) < time())) {
					# repeat down notification every 'repeat' time interval
					if ($d->{sms_notification}) {
						system(qq[gammu-smsd-inject EMS $d->{sms_notification} -unicode -text "$down_message"]);
						warn(qq[gammu-smsd-inject EMS $d->{sms_notification} -unicode -text "$down_message"]);
					}
					$dbh->do(qq[UPDATE alarms SET \
									last_notification = ] . time() . qq[, \
									alarm_state = 1 \
									WHERE `serial` like $quoted_serial]) or warn $!;
					syslog('info', "serial $serial: down repeat");
					warn "down repeat\n";
				}
#				print "true\n";
			}
			else {
				# condition not met
				if ($d->{alarm_state} == 1) {
					# changed from alarm to no alarm - send sms
					if ($d->{sms_notification}) {
						system(qq[gammu-smsd-inject EMS $d->{sms_notification} -unicode -text "$up_message"]);
						warn(qq[gammu-smsd-inject EMS $d->{sms_notification} -unicode -text "$up_message"]);
					}
					syslog('info', "serial $serial: up");
					warn "up\n";
				}
				$dbh->do(qq[UPDATE alarms SET \
								last_notification = ] . time() . qq[, \
								alarm_state = 0 \
								WHERE `serial` like $quoted_serial]) or warn $!;
#				print "false\n";
			}
		}
	}
}



__END__
