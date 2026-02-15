package Nabovarme::Db;

use strict;
use warnings;
use DBI;
use Sys::Syslog;

# Database configuration from environment
my $db_host		= $ENV{'METERLOGGER_DB_HOST'}		or die "METERLOGGER_DB_HOST not set";
my $db_user		= $ENV{'METERLOGGER_DB_USER'}		or die "METERLOGGER_DB_USER not set";
my $db_password	= $ENV{'METERLOGGER_DB_PASSWORD'}	or die "METERLOGGER_DB_PASSWORD not set";
my $METERLOGGER_DB_PORT		= $ENV{'METERLOGGER_DB_PORT'}					or die "METERLOGGER_DB_PORT not set";
my $METERLOGGER_DB_NAME		= $ENV{'METERLOGGER_DB_NAME'}					or die "METERLOGGER_DB_NAME not set";

my $dbi = "DBI:mysql:database=$METERLOGGER_DB_NAME;host=$db_host;port=$METERLOGGER_DB_PORT";

sub my_connect {
	my $dbh = DBI->connect(
		$dbi,
		$db_user,
		$db_password,
		{ mysql_auto_reconnect => 1, mysql_enable_utf8 => 1 }
	);
	
	unless ($dbh) {
		warn "DB connect failed: $DBI::errstr";
		return undef;
	}
	
	return $dbh;
}

1;
