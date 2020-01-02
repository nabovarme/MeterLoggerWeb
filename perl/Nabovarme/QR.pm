package Nabovarme::QR;

use utf8;
use strict;
use Data::Dumper;
use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::Const;
use DBI;
use Fcntl qw(:flock);

use lib qw( /etc/apache2/perl );
#use lib qw( /opt/local/apache2/perl );
use Nabovarme::Db;

sub handler {
	my $r = shift;
	my ($dbh, $sth, $sth2, $d, $d2);
	
	my $qr_path = $r->dir_config('QRPath') || '/qr';
	my $latex_template_name = $r->dir_config('QRLatexTemplateName') || 'template.tex';
	my $document_root = $r->document_root();
	my $latex_template = $document_root . $qr_path . '/' . $latex_template_name;

	my ($serial, $option) = $r->uri =~ m|^/[^/]+/([^/]+)(?:/([^/]+))?|;
	warn Dumper {uri => $r->uri, serial => $serial, option => $option};
	my $quoted_serial;
	
	if ($dbh = Nabovarme::Db->my_connect) {
		$quoted_serial = $dbh->quote($serial);
		
		if ( (-e $document_root . $qr_path . '/' . $serial . '.pdf') && 
			 ((time() - (stat($document_root . $qr_path . '/' . $serial . '.pdf'))[9] < 3600)) ) {
			warn Dumper "cached version exists: " . $document_root . $qr_path . '/' . $serial . '.pdf' . " changed " . (time() - (stat($document_root . $qr_path . '/' . $serial . '.pdf'))[9]) . " seconds ago";
		}
		else {
			warn Dumper "no valid cache found: " . $document_root . $qr_path . '/' . $serial . '.pdf' . " we need to create it";
			
			$sth = $dbh->prepare(qq[SELECT \
				serial, \
				info, \
				sms_notification \
				FROM `meters` WHERE `serial` LIKE ] . $quoted_serial);
			$sth->execute;
			if ($sth->rows) {
				if ($d = $sth->fetchrow_hashref) {
					my $info = $d->{info};
					my $sms = $d->{sms_notification};
					utf8::decode($info);
					utf8::decode($sms);
					system(qq[cd $document_root$qr_path && \
					latex "\\newcommand{\\varserial}{$serial} \\newcommand{\\varinfo}{$info} \\newcommand{\\varsms}{$sms} \\input{$latex_template_name}" && \
					dvips template.dvi && \
					ps2pdf template.ps && \
					mv template.pdf $serial.pdf && \
					rm template.dvi template.ps template.aux template.log]) ;
				}
			}
			else {
				return Apache2::Const::NOT_FOUND;
			}

		}
		$r->sendfile($document_root . $qr_path . '/' . $serial . '.pdf');
		return Apache2::Const::OK;
	}	
}

1;

__END__
