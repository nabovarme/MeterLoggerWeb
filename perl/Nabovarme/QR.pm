package Nabovarme::QR;

use utf8;
use strict;
use Data::Dumper;
use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::Const;
use DBI;
use Fcntl qw(:flock);

use Nabovarme::Db;

sub latex_escape {
	my $s = shift // '';

	$s =~ s/\\/\\textbackslash{}/g;
	$s =~ s/([#\$%&_{}])/\\$1/g;

	$s =~ s/~/\\textasciitilde{}/g;
	$s =~ s/\^/\\textasciicircum{}/g;

	return $s;
}

sub uri_escape {
	my $s = shift // '';
	$s =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X", ord($1))/ge;
	return $s;
}

sub handler {
	my $r = shift;
	my ($dbh, $sth, $sth2, $d, $d2);
	
	my $qr_path = $r->dir_config('QRPath') || '/qr';
	my $latex_template_name = $r->dir_config('QRLatexTemplateName') or die "QRLatexTemplateName is not configured";
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
			
			$sth = $dbh->prepare(qq[
				SELECT m.serial, m.info, m.sms_notification, g.mobile_pay_receiver
				FROM meters m
				LEFT JOIN meter_groups g ON m.group = g.id
				WHERE m.serial = ] . $quoted_serial);
			$sth->execute;
			if ($sth->rows) {
				if ($d = $sth->fetchrow_hashref) {
					my $info = $d->{info};
					my $sms = $d->{sms_notification};
					my $mobilepay_receiver = $d->{mobile_pay_receiver};

					if (!defined $mobilepay_receiver || $mobilepay_receiver eq '') {
						return Apache2::Const::NOT_FOUND;
					}

					my $info_esc = latex_escape($info);
					my $sms_esc = latex_escape($sms);
					my $serial_esc = latex_escape($serial);
					my $mobilepay_esc = latex_escape($mobilepay_receiver);
					my $comment = uri_escape("$serial, $info");
					eval {
						warn(qq[cd $document_root$qr_path && \
						qrencode -o qr_meterlogger.png -v 4 -s 16 "https://meterlogger.net/detail_acc.epl?serial=$serial" ; \
						qrencode -o qr_mobilepay.png -v 4 -s 16 "https://www.mobilepay.dk/erhverv/betalingslink/betalingslink-svar?phone=$mobilepay_receiver&amount=&comment=$serial, NV" ; \ 
						mogrify -interpolate Integer -filter point -resize 256x256 *.png ;
						pdflatex "\\newcommand{\\varserial}{$serial} \\newcommand{\\varinfo}{$info} \\newcommand{\\varsms}{$sms} \\newcommand{\\varmobilepay}{$mobilepay_receiver} \\input{$latex_template_name}" ; \
						mv template.pdf $serial.pdf ; \
						rm qr_mobilepay.png qr_meterlogger.png]);

						system(qq[cd $document_root$qr_path && \
						qrencode -o qr_meterlogger.png -v 4 -s 16 "https://meterlogger.net/detail_acc.epl?serial=$serial" ; \
						qrencode -o qr_mobilepay.png -v 4 -s 16 "mobilepay://send?phone=$mobilepay_receiver&amount=&comment=$comment" ; \ 
						mogrify -interpolate Integer -filter point -resize 256x256 *.png ;
						pdflatex "\\newcommand{\\varserial}{$serial_esc} \\newcommand{\\varinfo}{$info_esc} \\newcommand{\\varsms}{$sms_esc} \\newcommand{\\varmobilepay}{$mobilepay_esc} \\input{$latex_template_name}" ; \
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