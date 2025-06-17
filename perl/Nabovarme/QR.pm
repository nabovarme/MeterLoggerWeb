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
	
	my $mobilepay_receiver = $r->dir_config('QRMobilePayReceiver') || '28490157';
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
					eval {
						warn(qq[cd $document_root$qr_path && \
						qrencode -o qr_meterlogger.png -v 4 -s 16 "https://meterlogger.net/detail_acc.epl?serial=$serial&low=1" ; \
						qrencode -o qr_mobilepay.png -v 4 -s 16 "https://www.mobilepay.dk/erhverv/betalingslink/betalingslink-svar?phone=$mobilepay_receiver&amount=&comment=$serial, NV" ; \ 
						mogrify -interpolate Integer -filter point -resize 256x256 *.png ;
						pdflatex "\\newcommand{\\varserial}{$serial} \\newcommand{\\varinfo}{$info} \\newcommand{\\varsms}{$sms} \\newcommand{\\varmobilepay}{$mobilepay_receiver} \\input{$latex_template_name}" ; \
						mv template.pdf $serial.pdf ; \
						rm qr_mobilepay.png qr_meterlogger.png]);

						system(qq[cd $document_root$qr_path && \
						qrencode -o qr_meterlogger.png -v 4 -s 16 "https://meterlogger.net/detail_acc.epl?serial=$serial&low=1" ; \
						qrencode -o qr_mobilepay.png -v 4 -s 16 "https://www.mobilepay.dk/erhverv/betalingslink/betalingslink-svar?phone=$mobilepay_receiver&amount=&comment=$serial, NV" ; \ 
						mogrify -interpolate Integer -filter point -resize 256x256 *.png ;
						pdflatex "\\newcommand{\\varserial}{$serial} \\newcommand{\\varinfo}{$info} \\newcommand{\\varsms}{$sms} \\newcommand{\\varmobilepay}{$mobilepay_receiver} \\input{$latex_template_name}" ; \
						mv template.pdf $serial.pdf ; \
						rm qr_mobilepay.png qr_meterlogger.png]);
					};
					if ($@) {
						warn "Something bad happened: $@\n";
					}
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
