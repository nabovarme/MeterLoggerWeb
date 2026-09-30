#!/usr/bin/perl -w

use strict;
use warnings;
use POSIX qw( mktime localtime strftime );

use Nabovarme::Db;
use Nabovarme::Admin;
use Nabovarme::Utils;

# Enable autoflush for stdout/stderr logs
$| = 1;

log_info("Starting subscription processing run...");

my $admin = Nabovarme::Admin->new()
	or log_die("Cannot initialize Nabovarme::Admin module: $!");

my $dbh = $admin->{dbh};

my $now = time();

# Select enabled subscriptions due for payment ONLY if the serial exists and is enabled in the meters table
my $sth = $dbh->prepare(qq[
	SELECT 
		s.id, 
		s.serial, 
		s.amount, 
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
	my $sub_id       = $sub->{id};
	my $serial       = $sub->{serial};
	# Ensure the amount is NEGATIVE to deduct from the meter's balance
	my $amount       = -abs($sub->{amount});
	my $price        = 1; # Fixed price multiplier for fiat currency charges
	my $frequency    = $sub->{frequency};
	my $prefix       = (defined $sub->{info_prefix} && length $sub->{info_prefix}) 
	                   ? $sub->{info_prefix} 
	                   : 'Subscription';

	my $start_time   = $sub->{next_payment_time};
	my $next_time    = calculate_next_payment_time($start_time, $frequency, $now);

	# End of period is 1 second before next period starts
	my $end_time     = $next_time - 1;

	# Format dates as dd.mm.yyyy (e.g. 01.10.2026-31.10.2026)
	my $start_str    = strftime('%d.%m.%Y', localtime($start_time));
	my $end_str      = strftime('%d.%m.%Y', localtime($end_time));

	# Combine prefix and date range: "Abonnement 01.10.2026-31.10.2026"
	my $info         = sprintf('%s %s-%s', $prefix, $start_str, $end_str);

	eval {
		$admin->process_subscription_charge(
			$sub_id,
			$serial,
			$amount,
			$price,
			$info,
			$now,
			$next_time
		);
		$processed_count++;
		log_info("Created subscription charge: serial $serial, amount: $amount, info: '$info'");
	};
	if ($@) {
		log_warn("Failed to process subscription charge for sub ID $sub_id (serial $serial): $@");
	}
}

log_info("Subscription processing finished. Total processed: $processed_count");

# --- Helper Functions ---

sub calculate_next_payment_time {
	my ($current_target, $frequency, $now) = @_;

	my ($sec, $min, $hour, $mday, $mon, $year) = localtime($current_target);

	# Increment months/years based on interval frequency
	if ($frequency eq 'monthly') {
		$mon += 1;
	}
	elsif ($frequency eq 'quarterly') {
		$mon += 3;
	}
	elsif ($frequency eq 'yearly') {
		$year += 1;
	}

	# Force day to 1st of the month at midnight (00:00:00) with DST auto-detection (-1)
	my $next_target = mktime(0, 0, 0, 1, $mon, $year, 0, 0, -1);

	# Catch-up loop: if calculation is still in the past relative to execution time, push forward
	while ($next_target <= $now) {
		($sec, $min, $hour, $mday, $mon, $year) = localtime($next_target);
		if ($frequency eq 'monthly')      { $mon += 1; }
		elsif ($frequency eq 'quarterly')  { $mon += 3; }
		elsif ($frequency eq 'yearly')     { $year += 1; }
		$next_target = mktime(0, 0, 0, 1, $mon, $year, 0, 0, -1);
	}

	return $next_target;
}

1;
