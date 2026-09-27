#!/usr/bin/env perl
use strict;
use warnings;
use Crypt::PK::ECC;
use MIME::Base64 qw(encode_base64url);

my $pk = Crypt::PK::ECC->new();
$pk->generate_key('prime256v1');

# Export raw uncompressed public key (65 bytes) and raw private key (32 bytes)
my $public_key_raw  = $pk->export_key_raw('public');
my $private_key_raw = $pk->export_key_raw('private');

# Encode to URL-safe Base64 without padding
my $pub_b64  = encode_base64url($public_key_raw);
my $priv_b64 = encode_base64url($private_key_raw);

print "\n=======================================\n";
print "VAPID Keys Generated Successfully:\n";
print "=======================================\n\n";
print "Add or update the following environment variables in your .env file:\n\n";
print "VAPID_PUBLIC_KEY=\"$pub_b64\"\n";
print "VAPID_PRIVATE_KEY=\"$priv_b64\"\n";
print "VAPID_SUBJECT=\"mailto:admin\@meterlogger.net\"\n\n";
print "=======================================\n";
