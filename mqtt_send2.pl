#!/usr/bin/perl -w

use strict;
use Data::Dumper;
use Sys::Syslog;
use Time::HiRes qw( usleep );

use Nabovarme::MQTT_RPC;

openlog($0, "ndelay,pid", "local0");
syslog('info', "starting...");

sub my_callback {
	warn Dumper "my_callback";
	warn Dumper @_;
}

my $nabovarme_mqtt = new Nabovarme::MQTT_RPC;

$nabovarme_mqtt->connect() || die $!;
my $ret = $nabovarme_mqtt->call({	serial => $ARGV[0] || '9999999',
						function => $ARGV[1] || "version",
						param => $ARGV[2] || '1',
#						callback => undef,
						callback => \&my_callback,
						timeout => 10
					});
if ($ret) {
	print "succes\n";
	print Dumper $ret;
}
else {
	print "failed\n";
	print Dumper $ret;
}			
1;



__END__
