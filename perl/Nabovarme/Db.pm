package Nabovarme::Db;

use strict;
use warnings;
use utf8;
use DBI;

# Keep a persistent lexical handle cache across requests in the mod_perl worker
our $cached_dbh;

sub my_connect {
	# 1. Fast path: check if our global connection is alive and kicking
	if ($cached_dbh && $cached_dbh->ping) {
		return $cached_dbh;
	}

	# 2. Slow path: connect_cached automatically creates or revives identical handles
	my $dbh = DBI->connect_cached(
		'dbi:mysql:',
		'',
		'',
		{ 
			mysql_read_default_file => '/etc/mysql/my.cnf', 
			mysql_auto_reconnect    => 1, 
			mysql_enable_utf8mb4    => 1,
			PrintError              => 0,
			RaiseError              => 0,
		}
	);
	
	unless ($dbh) {
		warn "DB connect failed: $DBI::errstr";
		return undef;
	}
	
	$cached_dbh = $dbh;
	return $dbh;
}

1;
