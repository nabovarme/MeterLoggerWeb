#!/usr/bin/perl -w

use strict;
use Data::Dumper;
use Sys::Syslog;
use DBI;
use Config;

use lib qw( /etc/apache2/perl );
use lib qw( /opt/local/apache2/perl/ );
use Nabovarme::Db;

use constant CLOSE_WARNING_TIME => 3 * 24;

#$SIG{HUP} = \&get_version_and_status;

#$SIG{INT} = \&sig_int_handler;

openlog($0, "ndelay,pid", "local0");
syslog('info', "starting...");

my $unix_time;
my $meter_serial;
my $mqtt_data = undef;
#my $mqtt_count = 0;

my $dbh;
my $sth;
my $sth_kwh_remaining;
my $sth_energy_now;
my $sth_energy_last;
my $d;
my $d_energy_now;
my $d_energy_last;
my $d_kwh_remaining;

my $energy_now;
my $energy_last;
my $time_now;
my $time_last;
my $energy_last_day;

my $energy_remaining;
my $energy_time_remaining;

my $notification;

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
	$sth = $dbh->prepare(qq[SELECT `serial`, `info`, `min_amount`, `valve_status`, `sw_version`, `email_notification`, `sms_notification`, `close_notification_time`, `notification_state`, `notification_sent_at` FROM meters WHERE `enabled` AND `type` = 'heat' AND (`email_notification` OR `sms_notification`)]);
	$sth->execute;
	
	while ($d = $sth->fetchrow_hashref) {
		my $quoted_serial = $dbh->quote($d->{serial});
			
		# get kWh remaining from db
		$sth_kwh_remaining = $dbh->prepare(qq[SELECT ROUND( \
		(SELECT SUM(amount/price) AS paid_kwh FROM accounts WHERE serial = $quoted_serial) - \
		(SELECT \
			(SELECT samples_cache.energy FROM samples_cache WHERE samples_cache.serial = $quoted_serial ORDER BY samples_cache.unix_time DESC LIMIT 1) - \
			(SELECT meters.setup_value FROM meters WHERE meters.serial = $quoted_serial) AS consumed_kwh \
		), 2) AS kwh_remaining]);
		$sth_kwh_remaining->execute;

		# get last days energy usage
		$sth_energy_now = $dbh->prepare(qq[SELECT `energy`, `unix_time` FROM nabovarme.samples_cache \
			WHERE `serial` = $quoted_serial ORDER BY unix_time DESC LIMIT 1]);
		$sth_energy_now->execute;
		if ($sth_energy_now->rows) {
			if ($d_energy_now = $sth_energy_now->fetchrow_hashref) {
				$energy_now = $d_energy_now->{energy};
				$time_now = $d_energy_now->{unix_time};
			}
		}

		$sth_energy_last = $dbh->prepare(qq[SELECT `energy`, `unix_time` FROM nabovarme.samples_cache \
			WHERE `serial` = $quoted_serial \
			AND (from_unixtime(unix_time) < (FROM_UNIXTIME($time_now) - INTERVAL 24 HOUR)) ORDER BY unix_time DESC LIMIT 1]);
		$sth_energy_last->execute;
		if ($sth_energy_last->rows) {
			if ($d_energy_last = $sth_energy_last->fetchrow_hashref) {
				$energy_last = $d_energy_last->{energy} || 0;
				$time_last = $d_energy_last->{unix_time} || 0;
			}
		}
		if ((($time_now || 0) - ($time_last || 0)) > 0) {
			$energy_last_day = (($energy_now || 0) - ($energy_last || 0)) / ((($time_now || 0) - ($time_last || 0)) / 60 / 60);
		}

		if ($d_kwh_remaining = $sth_kwh_remaining->fetchrow_hashref) {
			$energy_remaining = ($d_kwh_remaining->{kwh_remaining} || 0) - ($d->{min_amount} || 0);
			if ($energy_last_day <= 0.0) {
				next;
			}

			$energy_time_remaining = $energy_remaining / $energy_last_day;
			
			if (($d->{notification_state}) == 0) {		# send close warning notification if not sent before
				if ($energy_time_remaining < (($d->{close_notification_time} / 3600) || CLOSE_WARNING_TIME)) {	# 3 days
					# send close warning
					syslog('info', "close warning sent for serial #" . $d->{serial} 
						. ", energy remaining: " . $energy_remaining 
						. ", energy now: " . $energy_now 
						. ", energy last: " . $energy_last 
						. ", time now: " . $time_now 
						. ", time last: " . $time_last);
					$notification = 'Nabovarme ' . $d->{info} . ' closing in ' . sprintf("%.0f", $energy_time_remaining / 24) . ' days. (' . $d->{serial} . ') ' . 
						'https://meterlogger.net/detail_acc.epl?serial=' . $d->{serial};
					if ($d->{sms_notification}) {
						sms_send($d->{sms_notification}, $notification);
					}
					$dbh->do(qq[UPDATE meters SET \
						notification_state = 1, \
						notification_sent_at = $energy_remaining \
						WHERE serial = $quoted_serial]) or warn $!;
						warn "serial: " . $d->{serial} . ", energy_time_remaining: " . $energy_time_remaining . "\n";
				}
			}
			elsif (($d->{notification_state}) == 1) {	# send close notification if not sent before
				if ($energy_remaining <= 0) {			# no energy remaining
					# send close message
					syslog('info', "close notice sent for serial #" . $d->{serial} 
						. ", energy remaining: " . $energy_remaining 
						. ", energy now: " . $energy_now 
						. ", energy last: " . $energy_last 
						. ", time now: " . $time_now 
						. ", time last: " . $time_last);
					$notification = 'Nabovarme ' . $d->{info} . ' closed. (' . $d->{serial} . ') ' . 
						'https://meterlogger.net/detail_acc.epl?serial=' . $d->{serial};
					if ($d->{sms_notification}) {
						sms_send($d->{sms_notification}, $notification);
					}
					$dbh->do(qq[UPDATE meters SET \
						notification_state = 2 \
						WHERE serial = $quoted_serial]) or warn $!;
				}
				elsif (($energy_time_remaining > 0) and ($energy_remaining > $d->{notification_sent_at})) {
					# send open message
					syslog('info', "open notice sent for serial #" . $d->{serial} 
						. ", energy remaining: " . $energy_remaining 
						. ", energy now: " . $energy_now 
						. ", energy last: " . $energy_last 
						. ", time now: " . $time_now 
						. ", time last: " . $time_last);
					$notification = 'Nabovarme ' . $d->{info} . ' open. ' . sprintf("%.0f", $energy_time_remaining / 24) . ' days remaining. (' . $d->{serial} . ') ' . 
						'https://meterlogger.net/detail_acc.epl?serial=' . $d->{serial};
					if ($d->{sms_notification}) {
						sms_send($d->{sms_notification}, $notification);
					}
					$dbh->do(qq[UPDATE meters SET \
						notification_state = 0 \
						WHERE serial = $quoted_serial]) or warn $!;
				}
			}
			elsif (($d->{notification_state}) == 2) {	# send open notification if not sent before
				if ($energy_time_remaining > 0) {
					# send open message
					syslog('info', "open notice sent for serial #" . $d->{serial} 
						. ", energy remaining: " . $energy_remaining 
						. ", energy now: " . $energy_now 
						. ", energy last: " . $energy_last 
						. ", time now: " . $time_now 
						. ", time last: " . $time_last);
					$notification = 'Nabovarme ' . $d->{info} . ' open. ' . sprintf("%.0f", $energy_time_remaining / 24) . ' days remaining. (' . $d->{serial} . ') ' . 
						'https://meterlogger.net/detail_acc.epl?serial=' . $d->{serial};
					if ($d->{sms_notification}) {
						sms_send($d->{sms_notification}, $notification);
					}
					$dbh->do(qq[UPDATE meters SET \
						notification_state = 0 \
						WHERE serial = $quoted_serial]) or warn $!;
				}
			}
		}
	}
	sleep 1;
}

# end of main

sub sms_send {
	my ($sms_notification, $message) = @_;
	my @sms_notifications;
	
	return unless $sms_notification;
	
	@sms_notifications = ($sms_notification =~ /(\d+)(?:,\s?)*/g);
	if (scalar(@sms_notifications) > 1) {
		foreach (@sms_notifications) {
			syslog('info', 'running ' . qq[/etc/apache2/perl/Nabovarme/bin/smstools_send.pl 45$_ "$message"]);
			system(qq[/etc/apache2/perl/Nabovarme/bin/smstools_send.pl 45$_ "$message"]);
			warn(qq[/etc/apache2/perl/Nabovarme/bin/smstools_send.pl 45$_ "$message"]);
		}
	}
	else {
		syslog('info', 'running ' . qq[/etc/apache2/perl/Nabovarme/bin/smstools_send.pl 45$sms_notification "$message"]);
		system(qq[/etc/apache2/perl/Nabovarme/bin/smstools_send.pl 45$sms_notification "$message"]);
		warn(qq[/etc/apache2/perl/Nabovarme/bin/smstools_send.pl 45$sms_notification "$message"]);
	}
}

sub sig_int_handler {

	die $!;
}

1;
__END__
