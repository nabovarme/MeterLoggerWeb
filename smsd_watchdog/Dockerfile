FROM debian:stable

# Install Perl, uhubctl, USB libraries, curl, and Docker from Debian repos
RUN apt-get update && apt-get install -y \
	perl \
	libnet-smtp-ssl-perl \
	libemail-mime-perl \
	ca-certificates \
	uhubctl \
	usb-modeswitch \
	libusb-1.0-0 \
	docker.io

# Copy watcher script
COPY ./perl /usr/local/lib/perl
COPY ./smsd_watchdog/watcher.pl /watcher.pl
RUN chmod +x /watcher.pl

WORKDIR /

ENV PERL5LIB=/usr/local/lib/perl:${PERL5LIB}

CMD ["/watcher.pl"]
