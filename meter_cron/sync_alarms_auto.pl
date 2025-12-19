#!/usr/bin/perl -w

# Perl script to sync auto-alarms from alarms_auto to alarms table
# Run once; suitable for cron execution
# Deletes alarms where the meter no longer exists

use strict;
use DBI;
use Config;

# Custom library path for database connection
use lib qw(/etc/apache2/perl);
use Nabovarme::Db;

$| = 1;  # Autoflush STDOUT

# Connect to MySQL database
my $dbh = Nabovarme::Db->my_connect or die "Can't connect to DB: $!";
$dbh->{'mysql_auto_reconnect'} = 1;
$dbh->{'AutoCommit'} = 0;   # Disable AutoCommit for transaction
$dbh->{'RaiseError'} = 1;   # Raise exceptions on errors

print "[".localtime()."] Connected to DB\n";

# Run sync once
eval {
	sync_auto_alarms();
	$dbh->commit;
};
if ($@) {
	warn "[".localtime()."] Error during auto-alarm sync: $@\n";
	$dbh->rollback;
}

$dbh->disconnect;

# -------------------------------
# Sync auto-alarms into alarms
# -------------------------------
sub sync_auto_alarms {
	print "[".localtime()."] Starting auto-alarm sync...\n";

	# Delete alarms for serials that no longer exist
	my $deleted = $dbh->do(q{
		DELETE FROM alarms
		WHERE serial NOT IN (SELECT `serial` FROM meters)
	});
	# Normalize DBI 0E0 value to 0 for printing
	my $num_deleted = ($deleted && $deleted eq '0E0') ? 0 : $deleted;
	print "[".localtime()."] Deleted $num_deleted alarms with missing meters\n";

	# Fetch all enabled auto alarms
	my $sth_aa = $dbh->prepare("SELECT * FROM alarms_auto WHERE enabled=1");
	$sth_aa->execute;

	# Fetch all enabled meters with valve_installed=1
	my $sth_m = $dbh->prepare("SELECT serial FROM meters WHERE enabled=1 AND valve_installed=1");
	$sth_m->execute;

	# Process each auto alarm
	while (my $aa = $sth_aa->fetchrow_hashref) {
		# Process each meter
		while (my $m = $sth_m->fetchrow_hashref) {
			my $serial = $m->{serial};

			# Check if the alarm already exists for this serial and auto_id
			my ($exists) = $dbh->selectrow_array(
				"SELECT 1 FROM alarms WHERE serial=? AND auto_id=?",
				undef, $serial, $aa->{id}
			);
			next if $exists;

			# Insert new alarm, using description for comment and sms_notification
			$dbh->do(q[
				INSERT INTO alarms
					(`serial`, `condition`, `down_message`, `up_message`, `repeat`, `default_snooze`, `enabled`, `auto_id`, `sms_notification`, `comment`)
				VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?, ?)
			], undef,
				$serial,
				$aa->{condition},
				$aa->{down_message} || 'alarm',
				$aa->{up_message}   || 'normal',
				$aa->{repeat}       || 0,
				$aa->{default_snooze} || 1800,
				$aa->{id},
				$aa->{sms_notification} || '',
				$aa->{description} || ''
			);

			print "[".localtime()."] Created auto-alarm for serial $serial from template $aa->{id}\n";
		}

		# Reset meters statement handle so it can be iterated again for the next auto alarm
		$sth_m->execute;
	}

	print "[".localtime()."] Auto-alarm sync complete.\n";
}
