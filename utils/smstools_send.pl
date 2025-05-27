#!/usr/bin/perl -w

use strict;
use Net::SMTP;
use Data::Dumper;

my $smtp = Net::SMTP->new('postfix') || die $!;

# destination and message text
my ($destination, $message) = @ARGV;

$smtp->mail('meterlogger');
if ($smtp->to($destination . '@meterlogger')) {
	$smtp->data();
	$smtp->datasend("$message");
	$smtp->dataend();
} else {
	print "Error: ", $smtp->message();
}

$smtp->quit;
# end of main


__END__
