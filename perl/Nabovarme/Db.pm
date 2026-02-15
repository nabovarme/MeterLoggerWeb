package Nabovarme::Db;

use strict;
use warnings;
use DBI;
use Sys::Syslog;

sub my_connect {
	my $dbh = DBI->connect(
		'dbi:mysql:',
		'',
		'',
		{ mysql_read_default_file => '/etc/mysql/my.cnf', mysql_auto_reconnect => 1, mysql_enable_utf8 => 1 }
	);
	
	unless ($dbh) {
		warn "DB connect failed: $DBI::errstr";
		return undef;
	}
	
	return $dbh;
}

1;
