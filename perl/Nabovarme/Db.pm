package Nabovarme::Db;

use strict;
use warnings;
use DBI;

sub my_connect {
	my ($dbi, $user, $pass, $opts);

	# --- Try environment variables first ---
	if ($ENV{'METERLOGGER_DB_HOST'} && $ENV{'METERLOGGER_DB_USER'} && $ENV{'METERLOGGER_DB_PASSWORD'}) {
		my $db_host     = $ENV{'METERLOGGER_DB_HOST'};
		my $db_user     = $ENV{'METERLOGGER_DB_USER'};
		my $db_password = $ENV{'METERLOGGER_DB_PASSWORD'};
		my $db_port     = $ENV{'METERLOGGER_DB_PORT'} || 3306;
		my $db_name     = $ENV{'METERLOGGER_DB_NAME'} || '';

		$dbi = "DBI:mysql:database=$db_name;host=$db_host;port=$db_port";
		$user = $db_user;
		$pass = $db_password;
		$opts = { mysql_auto_reconnect => 1, mysql_enable_utf8 => 1 };
	}
	else {
		# --- Fall back to /etc/mysql/my.cnf ---
		$dbi  = "DBI:mysql:";
		$user = '';
		$pass = '';
		$opts = { mysql_read_default_file => '/etc/mysql/my.cnf', mysql_auto_reconnect => 1, mysql_enable_utf8 => 1 };
	}

	my $dbh = DBI->connect($dbi, $user, $pass, $opts);

	unless ($dbh) {
		warn "DB connect failed: $DBI::errstr";
		return undef;
	}

	return $dbh;
}

1;
