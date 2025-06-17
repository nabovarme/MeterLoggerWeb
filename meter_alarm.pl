#!/usr/bin/perl -w

use strict;
use Data::Dumper;
use DBI;
use Statistics::Basic qw( :all );
use Math::Random::Secure qw(rand);
use Config;

use lib qw( /etc/apache2/perl );
use lib qw( /opt/local/apache2/perl/ );
use Nabovarme::Db;

# connect to db
my $dbh;
if ($dbh = Nabovarme::Db->my_connect) {
	$dbh->{'mysql_auto_reconnect'} = 1;
	warn "connected to db";
}
else {
	warn "cant't connect to db $!";
	die $!;
}

while (1) {
	check_conditions();
	sleep 60;
}

# end of main

sub check_conditions {
	my $sth = $dbh->prepare(qq[SELECT alarms.`id`,
									alarms.`serial`,
									meters.`info`,
									meters.`last_updated`,
									alarms.`condition`,
									alarms.`last_notification`,
									alarms.`alarm_state`,
									alarms.`repeat`,
									alarms.`snooze`,
									alarms.`default_snooze`,
									alarms.`snooze_auth_key`,
									alarms.`sms_notification`,
									alarms.`down_message`,
									alarms.`up_message`
								FROM `alarms`, `meters`
								WHERE alarms.`serial` = meters.`serial`
								AND alarms.`enabled`]);
	$sth->execute;
	if ($sth->rows) {
		my $id;
		my $quoted_id;
		
		my $serial;
		my $quoted_serial;
		my $info;
		my $last_updated;
		my $offline;
		my $default_snooze;
		my $condition;
		my $condition_var;
		my @condition_vars;
		my $eval_alarm_state;
		my $down_message_var;
		my @down_message_vars;
		my $up_message_var;
		my @up_message_vars;
		my $down_message;
		my $up_message;
		my $d;
		
		my $snooze_auth_key;
		my $quoted_snooze_auth_key;
		
		while ($d = $sth->fetchrow_hashref) {
			# check every alarm in database
			$id = $d->{id};
			$quoted_id = $dbh->quote($id);
			
			$condition = $d->{condition};
			$serial = $d->{serial};
			$quoted_serial = $dbh->quote($serial);
			$info = $d->{info};
			$last_updated = $d->{last_updated};
			$offline = time() - $last_updated;
			$default_snooze = $d->{default_snooze};
			$down_message = $d->{down_message} || 'alarm';
			$up_message = $d->{up_message} || 'normal';
			
			# create random key for snooze auth
			$snooze_auth_key = $d->{snooze_auth_key} || join(q[], map(sprintf("%02x", int rand(256)), 1..8));
			$quoted_snooze_auth_key = $dbh->quote($snooze_auth_key);

			# replace $snooze_auth_key with generated key
			$down_message =~ s/\$snooze_auth_key/$snooze_auth_key/g;
			$up_message =~ s/\$snooze_auth_key/$snooze_auth_key/g;
			
			# replace $default_snooze with the one in alarms db
			$down_message =~ s/\$default_snooze/$default_snooze/g;
			$up_message =~ s/\$default_snooze/$default_snooze/g;
			
			# replace $serial with actual serial in message texts
			$down_message =~ s/\$serial/$serial/g;
			$up_message =~ s/\$serial/$serial/g;
#			warn $down_message;
			
			# replace $info with info for serial in message texts
			$down_message =~ s/\$info/$info/g;
			$up_message =~ s/\$info/$info/g;
			
			# replace $id_hash with hashed id of the alarm record 
			$down_message =~ s/\$id/$id/g;
			$up_message =~ s/\$id/$id/g;
			
			if (@down_message_vars = ($down_message =~ /\$(\w+)/g)) {
				if (@condition_vars = ($condition =~ /\$(\w+)/g)) {
					# we need to look up median value for passed condition variables
					for $condition_var (@condition_vars) {
						next if $condition_var =~ /^last_updated$/;
						next if $condition_var =~ /^offline$/;
						
						if ($condition_var eq 'last_volume') {
							my $sth_last = $dbh->prepare(qq[
								SELECT `volume`
								FROM `samples_cache`
								WHERE `serial` = $quoted_serial
								ORDER BY `unix_time` DESC
								LIMIT 1 OFFSET 1
							]);
							$sth_last->execute;
							if (my $row = $sth_last->fetchrow_hashref) {
								my $last_volume = $row->{volume} + 0.0;
								$condition =~ s/\$last_volume/$last_volume/g;
								$down_message =~ s/\$last_volume/$last_volume/g;
								$up_message =~ s/\$last_volume/$last_volume/g;
							}
							else {
								$condition =~ s/\$last_volume/0/g;
								$down_message =~ s/\$last_volume/0/g;
								$up_message =~ s/\$last_volume/0/g;
							}
						}
						elsif ($condition_var eq 'valve_status') {
							my $sth_valve = $dbh->prepare(qq[
								SELECT `valve_status`
								FROM `samples_cache`
								WHERE `serial` = $quoted_serial
								ORDER BY `unix_time` DESC
								LIMIT 1
							]);
							$sth_valve->execute;
							if (my $row = $sth_valve->fetchrow_hashref) {
								my $valve = $dbh->quote($row->{valve_status});
								$condition =~ s/\$valve_status/$valve/g;
								$down_message =~ s/\$valve_status/$valve/g;
								$up_message =~ s/\$valve_status/$valve/g;
							}
							else {
								$condition =~ s/\$valve_status/''/g;
								$down_message =~ s/\$valve_status/''/g;
								$up_message =~ s/\$valve_status/''/g;
							}
						}
						else {
							my $quoted_condition_var = '`' . $condition_var . '`';
							my $values = [];
							my $median;
							my $sth_condition_vars = $dbh->prepare(qq[
								SELECT $quoted_condition_var 
								FROM `samples_cache`
								WHERE `serial` LIKE $quoted_serial 
								ORDER BY `unix_time` DESC LIMIT 5
							]);
							if ($sth_condition_vars->execute) {
								if (!$@ and $sth_condition_vars->rows) {
									$values = $sth_condition_vars->fetchall_arrayref;
									$median = median(map(@$_, @$values)) + 0.0;
									$condition =~ s/\$$condition_var/$median/x;
									$down_message =~ s/\$$condition_var/$median/x;
									$up_message =~ s/\$$condition_var/$median/x;
								}
							}
						}
					}
				}
			}
			
			if (@up_message_vars = ($up_message =~ /\$(\w+)/g)) {
				# we need to look up symbolic variables
				for $up_message_var (@up_message_vars) {
					next if $up_message_var =~ /^id$/;	# dont lookup $id
					next if $up_message_var =~ /^last_updated$/;
					if ($up_message_var =~ /^offline$/) {
						$up_message =~ s/\$offline/$offline/g;
					}
					else {
						my $quoted_up_message_var = '`' . $up_message_var . '`';
						my $values = [];
						my $median;
						my $sth_up_message_vars = $dbh->prepare(qq[SELECT ] . $quoted_up_message_var . qq[
																	FROM `samples_cache`
																	WHERE `serial` like ] . $quoted_serial . qq[
																	ORDER BY `unix_time` DESC LIMIT 5]);
						$sth_up_message_vars->execute;
						if ($sth_up_message_vars->rows) {
							$values = $sth_up_message_vars->fetchall_arrayref;
							$median = median(map(@$_, @$values)) + 0.0;	# hack to convert , to .
							# replace symbol with value from database
							$up_message =~ s/\$$up_message_var/$median/x;
						}
					}
				}
				
			}
			
			if (@condition_vars = ($condition =~ /\$(\w+)/g)) {
				# we need to look up median value for passed condition variables
				for $condition_var (@condition_vars) {
					next if $condition_var =~ /^last_updated$/;
					next if $condition_var =~ /^offline$/;
					
					my $quoted_condition_var = '`' . $condition_var . '`';
					my $values = [];
					my $median;
					my $sth_condition_vars = $dbh->prepare(qq[SELECT ] . $quoted_condition_var . qq[
																FROM `samples_cache`
																WHERE `serial` like ] . $quoted_serial . qq[
																ORDER BY `unix_time`
																DESC LIMIT 5]);
					if ($sth_condition_vars->execute) {
						if (!$@ and $sth_condition_vars->rows) {
							$values = $sth_condition_vars->fetchall_arrayref;
							$median = median(map(@$_, @$values)) + 0.0;	# hack to convert , to .
							# replace symbol with value from database
							$condition =~ s/\$$condition_var/$median/x;
							$down_message =~ s/\$$condition_var/$median/x;
							$up_message =~ s/\$$condition_var/$median/x;
						}
					}
				}
			}
			
			warn "checking condition for serial $serial: $condition";
			$eval_alarm_state = eval 'no strict; ' . $condition;
			if ($@) {
				warn "error parsing condition for serial $serial: $condition, error: $@";
			}
			else {
				if ($eval_alarm_state) {
					# condition met, an alarm should be sent if we not dit it in the latest repeat time interval
					if ($d->{alarm_state} == 0) {
						# changed from no alarm to alarm - send sms
						sms_send($d->{sms_notification}, $down_message);
						$dbh->do(qq[UPDATE alarms SET
										last_notification = ] . time() . qq[,
										alarm_state = 1,
										snooze_auth_key = $quoted_snooze_auth_key
										WHERE `id` like $quoted_id ]) or warn $!;
						warn "serial $serial: down";
					}
					elsif ($d->{repeat} && (($d->{last_notification} + $d->{repeat} + $d->{snooze}) < time())) {
						# repeat down notification every 'repeat' time interval
						sms_send($d->{sms_notification}, $down_message);
						$dbh->do(qq[UPDATE alarms SET
										last_notification = ] . time() . qq[,
										alarm_state = 1,
										snooze = 0,
										snooze_auth_key = $quoted_snooze_auth_key
										WHERE `id` like $quoted_id]) or warn $!;
						warn "serial $serial: down repeat";
					}
#					print "true\n";
				}
				else {
					# condition not met
					if ($d->{alarm_state} == 1) {
						# changed from alarm to no alarm - send sms
						sms_send($d->{sms_notification}, $up_message);
						$dbh->do(qq[UPDATE alarms SET
										last_notification = ] . time() . qq[,
										alarm_state = 0,
										snooze = 0,
										snooze_auth_key = ''
										WHERE `id` like $quoted_id]) or warn $!;
						warn "serial $serial: up";
					}
#					print "false\n";
				}
			}
		}

	}
}

sub sms_send {
	my ($sms_notification, $message) = @_;
	my @sms_notifications;
	
	return unless $sms_notification;
	
	@sms_notifications = ($sms_notification =~ /(\d+)(?:,\s?)*/g);
	if (scalar(@sms_notifications) > 1) {
		foreach (@sms_notifications) {
			system(qq[/etc/apache2/perl/Nabovarme/bin/smstools_send.pl 45$_ "$message"]);
			warn(qq[/etc/apache2/perl/Nabovarme/bin/smstools_send.pl 45$_ "$message"]);
		}
	}
	else {
		system(qq[/etc/apache2/perl/Nabovarme/bin/smstools_send.pl 45$sms_notification "$message"]);
		warn(qq[/etc/apache2/perl/Nabovarme/bin/smstools_send.pl 45$sms_notification "$message"]);
	}
}


__END__
