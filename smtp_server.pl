#!/usr/bin/perl -w

use strict;
use Carp;

use File::Temp qw( tempfile );
use File::Basename;
use File::Copy;
use File::chown;
use Encode qw( encode decode );

use Net::SMTP::Server;
use Net::SMTP::Server::Client;
use Net::SMTP::Server::Relay;

use Email::Simple;

use Data::Dumper;

use constant SPOOL_DIR => '/var/spool/sms/outgoing';
#use constant SPOOL_DIR => '/tmp';
use constant USER => 'smsd';
use constant GROUP => 'smsd';


my $server = new Net::SMTP::Server('0.0.0.0', 25) ||
	croak("Unable to handle client connection: $!\n");

while (my $conn = $server->accept()) {
	my $client = new Net::SMTP::Server::Client($conn) ||
		croak("Unable to handle client connection: $!\n");

	$client->process || next;
#	print Dumper $client;

	for (@{$client->{TO}}) {
		# destination and message text
		my $destination = $_;
		$destination =~ s/\D//g;
		
		my $email = Email::Simple->new($client->{MSG});
		my $subject = $email->header('Subject') || '';
		my $body = $email->body || '';
		my $message = ($subject && $body) ? ($subject . ' ' . $body) : ($subject . $body);
#		print Dumper $email->header('To');
#		print Dumper ($destination, $message);

		# convert message from UTF-8 to UCS
		$message = encode('UCS-2BE', decode('UTF-8', $message));

		my ($fh, $temp_file) = tempfile();
		#binmode( $fh, ":utf8" );
		chown USER, GROUP, $temp_file;

		print $fh "To: " . $destination . "\n";
		print $fh "Alphabet: UCS\n";
		print $fh "\n";
		print $fh $message . "\n";

		my $lock_file = SPOOL_DIR . '/' . $destination . '_' . basename($temp_file) . '.LOCK';
		open(LOCK_FILE, ">>" . $lock_file) || die "Cannot open file: " . $!;
		close(LOCK_FILE);

		move($temp_file, SPOOL_DIR . '/' . $destination . '_' . basename($temp_file)) || die $!;

		unlink $lock_file;		
	}

}
