#!/usr/bin/perl -w

# Perl script to sync auto-alarms from alarms_auto to alarms table
# Run once; suitable for cron execution

use strict;
use Data::Dumper;
use DBI;
use Config;

# Custom library path for database connection
use lib qw(/etc/apache2/perl);
use Nabovarme::Db;

$| = 1;  # Autoflush STDOUT

# Connect to MySQL database
my $dbh = Nabovarme::Db->my_connect or die "Can't connect to DB: $!";
$dbh->{'mysql_auto_reconnect'} = 1;

print "[".localtime()."] Connected to DB\n";

# Run sync once
sync_auto_alarms();

# -------------------------------
# Sync auto-alarms into alarms
# -------------------------------
sub sync_auto_alarms {
	print "[".localtime()."] Starting auto-alarm sync...\n";

	# Fetch all enabled auto alarms
	my $auto_alarms = $dbh->selectall_arrayref(
		"SELECT * FROM alarms_auto WHERE enabled=1",
		{ Slice => {} }
	);

	# Fetch all enabled meters with valve_installed=1
	my $meters = $dbh->selectall_arrayref(
		"SELECT serial FROM meters WHERE enabled=1 AND valve_installed=1",
		{ Slice => {} }
	);

	for my $aa (@$auto_alarms) {
		for my $m (@$meters) {

			# Check if the alarm already exists for this serial and auto_id
			my ($exists) = $dbh->selectrow_array(
				"SELECT 1 FROM alarms WHERE serial=? AND auto_id=?",
				undef, $m->{serial}, $aa->{id}
			);
			next if $exists;

			# Insert new alarm
			$dbh->do(q[
				INSERT INTO alarms
					(`serial`, `condition`, `down_message`, `up_message`, `repeat`, `default_snooze`, `enabled`, `auto_id`, `sms_notification`)
				VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?)
			], undef,
				$m->{serial},
				$aa->{condition},
				$aa->{down_message} || 'alarm',
				$aa->{up_message}   || 'normal',
				$aa->{repeat}       || 0,
				$aa->{default_snooze} || 1800,
				$aa->{id},
				$aa->{sms_notification} || ''
			);

			print "[".localtime()."] Created auto-alarm for serial $m->{serial} from template $aa->{id}\n";
		}
	}

	print "[".localtime()."] Auto-alarm sync complete.\n";
}
