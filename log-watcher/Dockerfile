FROM debian:stable

# Install Perl, SMTP module, uhubctl and USB library
RUN apt-get update && apt-get install -y \
	perl \
	libnet-smtp-ssl-perl \
	ca-certificates \
	uhubctl \
	libusb-1.0-0

# Copy watcher script
COPY watcher.pl /watcher.pl
RUN chmod +x /watcher.pl

# Set working directory
WORKDIR /

# Run watcher
CMD ["/watcher.pl"]
