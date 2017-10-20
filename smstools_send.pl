#!/usr/bin/perl -w

use strict;
use File::Temp qw( tempfile );
use File::Basename;
use File::Copy;
use File::chown;
use Encode qw( encode decode );
use Data::Dumper;

use constant SPOOL_DIR => '/var/spool/sms/outgoing';
use constant USER => 'smsd';
use constant GROUP => 'smsd';

# destination and message text
my ($destination, $message) = @ARGV;

# convert message from UTF-8 to UCS
$message = encode('UCS-2BE', decode('UTF-8', $message));

my ($fh, $temp_file) = tempfile();
#binmode( $fh, ":utf8" );
chown USER, GROUP, $temp_file;

print $fh "To: " . $destination . "\n";
print $fh "Alphabet: UCS\n";
print $fh "\n";
print $fh $message . "\n";

move($temp_file, SPOOL_DIR . '/' . $destination . '_' . basename($temp_file)) || die $!;

# end of main


__END__
