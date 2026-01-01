#!/usr/bin/perl -w

# Perl script to sync auto-alarms from alarms_auto to alarms table
# Run once; suitable for cron execution
# Deletes alarms where the meter no longer exists and updates existing alarms if the template changed

use strict;
use DBI;
use Config;

use Nabovarme::Db;
use Nabovarme::Utils;

$| = 1;  # Autoflush STDOUT

# Connect to MySQL database
my $dbh = Nabovarme::Db->my_connect or log_die("Can't connect to DB: $!");
$dbh->{'mysql_auto_reconnect'} = 1;
$dbh->{'AutoCommit'} = 0;   # Disable AutoCommit for transaction
$dbh->{'RaiseError'} = 1;   # Raise exceptions on errors

log_info("Connected to DB");

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
	log_info("Starting auto-alarm sync...");

	# Delete alarms for serials that no longer exist
	my $deleted = $dbh->do(q{
		DELETE FROM alarms
		WHERE serial NOT IN (SELECT `serial` FROM meters)
	});
	# Normalize DBI 0E0 value to 0 for printing
	my $num_deleted = ($deleted && $deleted eq '0E0') ? 0 : $deleted;
	log_info("Deleted $num_deleted alarms with missing meters");

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

			# Skip if serial is missing or empty
			next unless defined $serial && length $serial;

			# Check if the alarm already exists for this serial and auto_id
			my ($exists) = $dbh->selectrow_array(
				"SELECT 1 FROM alarms WHERE serial=? AND auto_id=?",
				undef, $serial, $aa->{id}
			);

			if ($exists) {
				# Update the alarm to reflect changes in the template
				$dbh->do(q[
					UPDATE alarms
					SET
						`condition` = ?,
						`down_message` = ?,
						`up_message` = ?,
						`repeat` = ?,
						`default_snooze` = ?,
						`sms_notification` = ?,
						`comment` = ?
					WHERE serial = ? AND auto_id = ?
				], undef,
					$aa->{condition},
					$aa->{down_message} || 'alarm',
					$aa->{up_message}   || 'normal',
					$aa->{repeat}       || 0,
					$aa->{default_snooze} || 1800,
					$aa->{sms_notification} || '',
					$aa->{description} || '',
					$serial,
					$aa->{id}
				);

				log_info("Updated auto-alarm for serial $serial from template $aa->{id}");
			} else {
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

				log_info("Created auto-alarm for serial $serial from template $aa->{id}"); # <---- XXX DEBUG: meter_cron  | Use of uninitialized value $serial in concatenation (.) or string at /etc/apache2/perl/Nabovarme/bin/sync_alarms_auto.pl line 115, <FH> line 17.

			}
		}

		# Reset meters statement handle so it can be iterated again for the next auto alarm
		$sth_m->execute;
	}

	log_info("Auto-alarm sync complete.");
}
