#!/usr/bin/perl -w

use strict;
use warnings;
use POSIX qw( mktime localtime strftime );
use lib qw( /usr/local/share/perl /etc/apache2/perl );

use Nabovarme::Db;
use Nabovarme::Utils;

# Enable autoflush for stdout/stderr logs
$| = 1;

log_info("Starting subscription processing run...");

my $dbh = Nabovarme::Db->my_connect
	or log_die("Cannot connect to database: $!");

$dbh->{mysql_auto_reconnect} = 1;

my $now = time();

# Select enabled subscriptions due for payment ONLY if the serial exists and is enabled in the meters table
my $sth = $dbh->prepare(qq[
	SELECT 
		s.id, 
		s.serial, 
		s.amount, 
		s.price, 
		s.frequency, 
		s.info_prefix, 
		s.next_payment_time
	FROM subscriptions s
	JOIN meters m ON s.serial = m.serial
	WHERE s.enabled = 1
	  AND m.enabled = 1
	  AND s.next_payment_time <= ?
]);

$sth->execute($now) or log_die("Query failed: " . $dbh->errstr);

my $processed_count = 0;

while (my $sub = $sth->fetchrow_hashref) {
	my $serial       = $sub->{serial};
	# Ensure the amount is NEGATIVE to deduct from the meter's balance
	my $amount       = -abs($sub->{amount});
	my $price        = $sub->{price} || 1;
	my $frequency    = $sub->{frequency};
	my $prefix       = (defined $sub->{info_prefix} && length $sub->{info_prefix}) 
	                   ? $sub->{info_prefix} 
	                   : 'Abonnement';

	my $start_time   = $sub->{next_payment_time};
	my $next_time    = calculate_next_payment_time($start_time, $frequency, $now);

	# End of period is 1 second before next period starts
	my $end_time     = $next_time - 1;

	# Format dates as dd.mm.yyyy
	my $start_str    = strftime('%d.%m.%Y', localtime($start_time));
	my $end_str      = strftime('%d.%m.%Y', localtime($end_time));

	# Combine prefix and date range: "Abonnement 01.10.2026-31.10.2026"
	my $info         = sprintf('%s %s-%s', $prefix, $start_str, $end_str);

	# 1. Insert membership charge (negative amount) into `accounts`
	# NOTE: Trigger command_queue_insert_after will fire automatically and recalculate open_until!
	my $acc_sth = $dbh->prepare(qq[
		INSERT INTO accounts (type, serial, payment_time, amount, info, price, auto)
		VALUES ('membership', ?, ?, ?, ?, ?, 1)
	]);

	if ($acc_sth->execute($serial, $now, $amount, $info, $price)) {
		$processed_count++;
		log_info("Created subscription charge: serial $serial, amount: $amount, info: '$info'");

		# 2. Write record into audit log
		my $log_sth = $dbh->prepare(qq[
			INSERT INTO accounts_log (username, admin_group, serial, type, info, amount, price, remote_addr, user_agent, unix_time)
			VALUES ('system_cron', 'system', ?, 'membership_auto', ?, ?, ?, '127.0.0.1', 'meter_cron', ?)
		]);
		$log_sth->execute($serial, $info, $amount, $price, $now);

		# 3. Update subscription metadata with the new next_payment_time
		my $upd_sth = $dbh->prepare(qq[
			UPDATE subscriptions
			SET last_payment_time = ?,
			    next_payment_time = ?
			WHERE id = ?
		]);
		$upd_sth->execute($now, $next_time, $sub->{id});
	}
	else {
		log_warn("Failed to insert account charge for serial $serial: " . $dbh->errstr);
	}
}

$dbh->disconnect();
log_info("Subscription processing finished. Total processed: $processed_count");

# --- Helper Functions ---

sub calculate_next_payment_time {
	my ($current_target, $frequency, $now) = @_;

	my ($sec, $min, $hour, $mday, $mon, $year) = localtime($current_target);

	if ($frequency eq 'monthly') {
		$mon += 1;
	}
	elsif ($frequency eq 'quarterly') {
		$mon += 3;
	}
	elsif ($frequency eq 'yearly') {
		$year += 1;
	}

	my $next_target = mktime(0, 0, 0, $mday, $mon, $year);

	# If calculation is somehow still in the past, push it into the future
	while ($next_target <= $now) {
		($sec, $min, $hour, $mday, $mon, $year) = localtime($next_target);
		if ($frequency eq 'monthly')     { $mon += 1; }
		elsif ($frequency eq 'quarterly') { $mon += 3; }
		elsif ($frequency eq 'yearly')   { $year += 1; }
		$next_target = mktime(0, 0, 0, $mday, $mon, $year);
	}

	return $next_target;
}

1;
