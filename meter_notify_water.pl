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
my $sth_volume_left;
my $sth_volume_now;
my $sth_volume_last;
my $d;
my $d_volume_now;
my $d_volume_last;
my $d_volume_left;

my $volume_now;
my $volume_last;
my $time_now;
my $time_last;
my $volume_last_day;

my $volume_left;
my $volume_time_left;

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
	$sth = $dbh->prepare(qq[SELECT `serial`, `info`, `min_amount`, `valve_status`, `sw_version`, `email_notification`, `sms_notification`, `close_notification_time`, `notification_state`, `notification_sent_at` FROM meters WHERE `type` = 'water' AND (`email_notification` OR `sms_notification`)]);
	$sth->execute;
	
	while ($d = $sth->fetchrow_hashref) {
		my $quoted_serial = $dbh->quote($d->{serial});
			
		# get volume left from db
		$sth_volume_left = $dbh->prepare(qq[SELECT ROUND( \
		(SELECT SUM(amount/price) AS paid_volume FROM accounts WHERE serial = $quoted_serial) - \
		(SELECT \
			(SELECT samples_cache.volume FROM samples_cache WHERE samples_cache.serial = $quoted_serial ORDER BY samples_cache.unix_time DESC LIMIT 1) - \
			(SELECT meters.setup_value FROM meters WHERE meters.serial = $quoted_serial) AS consumed_volume \
		), 2) AS volume_left]);
		$sth_volume_left->execute;

		# get last days volume usage
		$sth_volume_now = $dbh->prepare(qq[SELECT `volume`, `unix_time` FROM nabovarme.samples_cache \
			WHERE `serial` = $quoted_serial ORDER BY unix_time DESC LIMIT 1]);
		$sth_volume_now->execute;
		if ($sth_volume_now->rows) {
			if ($d_volume_now = $sth_volume_now->fetchrow_hashref) {
				$volume_now = $d_volume_now->{volume};
				$time_now = $d_volume_now->{unix_time};
			}
		}

		$sth_volume_last = $dbh->prepare(qq[SELECT `volume`, `unix_time` FROM nabovarme.samples_cache \
			WHERE `serial` = $quoted_serial \
			AND (from_unixtime(unix_time) < (FROM_UNIXTIME($d_volume_now->{unix_time}) - INTERVAL 24 HOUR)) ORDER BY unix_time DESC LIMIT 1]);
		$sth_volume_last->execute;
		if ($sth_volume_last->rows) {
			if ($d_volume_last = $sth_volume_last->fetchrow_hashref) {
				$volume_last = $d_volume_last->{volume};
				$time_last = $d_volume_last->{unix_time};
			}
		}
		if ((($time_now || 0) - ($time_last || 0)) > 0) {
			$volume_last_day = (($volume_now || 0) - ($volume_last || 0)) / ((($time_now || 0) - ($time_last || 0)) / 60 / 60);
		}

		if ($d_volume_left = $sth_volume_left->fetchrow_hashref) {
			$volume_left = ($d_volume_left->{volume_left} || 0) - ($d->{min_amount} || 0);
			if ($volume_last_day <= 0.0) {
				next;
			}

			$volume_time_left = $volume_left / $volume_last_day;
			
			if (($d->{notification_state}) == 0) {		# send close warning notification if not sent before
				if ($volume_time_left < (($d->{close_notification_time} / 3600) || CLOSE_WARNING_TIME)) {	# 3 days
					# send close warning
					syslog('info', "close warning sent for serial #" . $d->{serial} 
						. ", volume left: " . $volume_left 
						. ", volume now: " . $volume_now 
						. ", volume last: " . $volume_last 
						. ", time now: " . $time_now 
						. ", time last: " . $time_last);
					$notification = 'Water closing in ' . sprintf("%.0f", $volume_time_left / 24) . ' days. (' . $d->{serial} . ') ' . 
						'https://meterlogger.net/detail_volume_acc.epl?serial=' . $d->{serial};
					if ($d->{sms_notification}) {
						sms_send($d->{sms_notification}, $notification);
					}
					$dbh->do(qq[UPDATE meters SET \
						notification_state = 1, \
						notification_sent_at = $volume_left \
						WHERE serial = $quoted_serial]) or warn $!;
						warn "serial: " . $d->{serial} . ", volume_time_left: " . $volume_time_left . "\n";
				}
			}
			elsif (($d->{notification_state}) == 1) {	# send close notification if not sent before
				if ($volume_left <= 0.0) {			# no volume left	DEBUG: we send it before becouse of rounding error in firmware
					# send close message
					syslog('info', "close notice sent for serial #" . $d->{serial} 
						. ", volume left: " . $volume_left 
						. ", volume now: " . $volume_now 
						. ", volume last: " . $volume_last 
						. ", time now: " . $time_now 
						. ", time last: " . $time_last);
					$notification = 'Water closed. (' . $d->{serial} . ') ' . 
						'https://meterlogger.net/detail_volume_acc.epl?serial=' . $d->{serial};
					if ($d->{sms_notification}) {
						sms_send($d->{sms_notification}, $notification);
					}
					$dbh->do(qq[UPDATE meters SET \
						notification_state = 2 \
						WHERE serial = $quoted_serial]) or warn $!;
				}
				elsif (($volume_left > 0.0) and ($volume_left > $d->{notification_sent_at})) {	# DEBUG: we send it before becouse of rounding error in firmware
					# send open message
					syslog('info', "open notice sent for serial #" . $d->{serial} 
						. ", volume left: " . $volume_left 
						. ", volume now: " . $volume_now 
						. ", volume last: " . $volume_last 
						. ", time now: " . $time_now 
						. ", time last: " . $time_last);
					$notification = 'Water open. ' . sprintf("%.0f", $volume_time_left / 24) . ' days left. (' . $d->{serial} . ') ' . 
						'https://meterlogger.net/detail_volume_acc.epl?serial=' . $d->{serial};
					if ($d->{sms_notification}) {
						sms_send($d->{sms_notification}, $notification);
					}
					$dbh->do(qq[UPDATE meters SET \
						notification_state = 0 \
						WHERE serial = $quoted_serial]) or warn $!;
				}
			}
			elsif (($d->{notification_state}) == 2) {	# send open notification if not sent before
				if ($volume_left > 0.0) {	# DEBUG: we send it before becouse of rounding error in firmware
					# send open message
					syslog('info', "open notice sent for serial #" . $d->{serial} 
						. ", volume left: " . $volume_left 
						. ", volume now: " . $volume_now 
						. ", volume last: " . $volume_last 
						. ", time now: " . $time_now 
						. ", time last: " . $time_last);
					$notification = 'Water open. ' . sprintf("%.0f", $volume_time_left / 24) . ' days left. (' . $d->{serial} . ') ' . 
						'https://meterlogger.net/detail_volume_acc.epl?serial=' . $d->{serial};
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
