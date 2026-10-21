package Nabovarme::APIOtaFirmware;

use strict;
use warnings;
use utf8;
use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::SubRequest ();
use Apache2::Const -compile => qw(OK HTTP_BAD_REQUEST HTTP_NOT_FOUND HTTP_SERVICE_UNAVAILABLE);
use CGI ();

use Nabovarme::Db;

sub handler {
	my $r = shift;

	# Use standard CGI module (installed via libcgi-pm-perl) to parse the query string
	my $cgi = CGI->new($r->args || '');
	my $serial  = $cgi->param('serial');
	my $slot    = $cgi->param('slot');
	my $version = $cgi->param('version');

	# Validate mandatory query params
	unless (defined $serial && $serial =~ /^\d{1,16}$/ && defined $slot && $slot =~ /^[01]$/) {
		return Apache2::Const::HTTP_BAD_REQUEST;
	}

	# Validate version parameter if provided
	if (defined $version && length($version) > 0) {
		unless ($version =~ /^[a-zA-Z0-9\.\_\-\+]{1,64}$/) {
			return Apache2::Const::HTTP_BAD_REQUEST;
		}
	} else {
		$version = undef;
	}

	# Map requested TARGET slot (0 or 1) to target binary name
	# Target Slot 0 requires user1.ota.bin
	# Target Slot 1 requires user2.ota.bin
	my $bin_name = ($slot eq '1') ? 'user2.ota.bin' : 'user1.ota.bin';

	# Verify meter exists in DB before serving firmware
	my $dbh = Nabovarme::Db->my_connect
		or return Apache2::Const::HTTP_SERVICE_UNAVAILABLE;

	my ($meter_exists) = $dbh->selectrow_array(
		"SELECT 1 FROM meters WHERE serial = ?", undef, $serial
	);

	unless ($meter_exists) {
		return Apache2::Const::HTTP_NOT_FOUND;
	}

	# Construct filesystem path to target firmware binary:
	# Use exact version directory if passed, otherwise default to "latest"
	my $doc_root      = $r->document_root || '/var/www/nabovarme';
	my $target_dir    = defined $version ? $version : 'latest';
	my $relative_path = "flasher/firmware/$serial/$target_dir/$bin_name";
	my $file_path     = "$doc_root/$relative_path";

	unless (-f $file_path) {
		return Apache2::Const::HTTP_NOT_FOUND;
	}

	# Internal redirect via mod_perl to stream binary with zero memory overhead
	$r->internal_redirect("/$relative_path");

	return Apache2::Const::OK;
}

1;
