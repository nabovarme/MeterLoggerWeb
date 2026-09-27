#!/usr/bin/env perl
use strict;
use warnings;
use JSON;

use Nabovarme::Push;
use Nabovarme::Number::Phone;
use Nabovarme::Utils qw(log_info log_warn);

# Destination phone number and message text from positional arguments
my ($destination, $message) = @ARGV;

unless ($destination && $message) {
	log_warn("Usage: $0 <destination_phone> <message_text> [title] [url]");
	exit 1;
}

my $title = $ARGV[2] || "MeterLogger Alert";
my $url   = $ARGV[3] || "/";

# Normalize destination phone number
my $phone_obj = Nabovarme::Number::Phone->new($destination);
my $target_phone = ($phone_obj && $phone_obj->is_valid) ? $phone_obj->compact : $destination;

# Build push payload matching system standard
my %payload = (
	title              => $title,
	body               => $message,
	url                => $url,
	tag                => "custom-cli-alert",
	renotify           => JSON::true,
	requireInteraction => JSON::true,
	vibrate            => [200, 100, 200],
	actions            => [
		{ action => "view", title => "View", url => $url }
	]
);

# Send Web Push notification
my $sent_count = Nabovarme::Push->send_notification_to_phone($target_phone, \%payload);

if ($sent_count > 0) {
	log_info("Successfully sent push notification to $sent_count device(s) for $target_phone");
	exit 0;
} else {
	log_warn("No active push subscriptions found or delivery failed for $target_phone");
	exit 1;
}

1;
