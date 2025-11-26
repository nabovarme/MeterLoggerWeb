FROM debian:stable

RUN apt-get update && apt-get install -y \
	perl \
	libnet-smtp-ssl-perl \
	ca-certificates

COPY watcher.pl /watcher.pl
RUN chmod +x /watcher.pl

CMD ["/watcher.pl"]
