#!/usr/bin/perl -w

use strict;
use Net::SMTP;

my $smtp = Net::SMTP->new('postfix') || die $!;

$smtp->mail('nabovarme');
if ($smtp->to('1234@meterlogger', '5678@meterlogger')) {
	$smtp->data();
	$smtp->datasend("Subject: test...\n");
#	$smtp->datasend("To: 9012\n");
	$smtp->datasend("\n");
	$smtp->datasend("...message\n");
	$smtp->dataend();
} else {
	print "Error: ", $smtp->message();
}

$smtp->quit;