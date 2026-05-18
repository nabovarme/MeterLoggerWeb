# smsd_watchdog

FROM perl-base:1.0

# Copy watcher script
COPY ./perl /usr/local/lib/perl
COPY ./smsd_watchdog/watcher.pl /watcher.pl
RUN chmod +x /watcher.pl

WORKDIR /

ENV PERL5LIB=/usr/local/lib/perl

CMD ["/watcher.pl"]
