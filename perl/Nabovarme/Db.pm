package Nabovarme::Db;

use strict;
use warnings;
use DBI;

use constant MAX_RECONNECT_ATTEMPTS => 5;
use constant RECONNECT_SLEEP_SECONDS => 2;

my $dbh;

sub _connect {
	for (my $i = 1; $i <= MAX_RECONNECT_ATTEMPTS; $i++) {

		my $h = DBI->connect(
			'dbi:mysql:',
			'',
			'',
			{
				mysql_read_default_file => '/etc/mysql/my.cnf',
				mysql_enable_utf8mb4    => 1,
				mysql_auto_reconnect    => 1,
			}
		);

		if ($h && $h->ping) {
			return $h;
		}

		warn "DB connect attempt $i failed: $DBI::errstr";

		sleep RECONNECT_SLEEP_SECONDS if $i < MAX_RECONNECT_ATTEMPTS;
	}

	return undef;
}

# --- THIS is the important part ---
sub my_connect {
	# If we already have a live handle, reuse it
	if ($dbh && $dbh->ping) {
		return $dbh;
	}

	# Otherwise reconnect transparently
	$dbh = _connect();

	return $dbh;
}

1;
