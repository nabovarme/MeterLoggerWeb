#!/usr/bin/perl -w

use strict;
use warnings;

use Nabovarme::Utils qw(send_notification log_info log_warn);

# destination and message text
my ($destination, $message) = @ARGV;
unless ($destination && $message) {
	log_warn("Usage: $0 <destination_number> <message>");
	exit 1;
}

log_info("Sending SMS to $destination: $message", { -custom_tag => 'SMS' });

if (send_notification($destination, $message)) {
	exit 0;   # success
} else {
	log_warn("Failed to send SMS to $destination", { -custom_tag => 'SMS' });
	exit 1;   # failure
}

__END__
