# web

FROM perl-base:1.0

LABEL maintainer="Kristoffer Ek <stoffer@skulp.net>"

RUN apt-get update && apt-get install -y --no-install-recommends \
# --- Graphics, QR & TeX Engine ---
imagemagick \
pbzip2 \
qrencode \
texlive \
texlive-fonts-extra \
texlive-latex-base \
texlive-latex-extra \
# --- Apache Web Server & mod_perl ---
apache2 \
apache2-bin \
apache2-doc \
apache2-utils \
libapache2-mod-perl2 \
libapache2-mod-perl2-dev \
libapache2-mod-perl2-doc \
libapache2-reload-perl \
libembperl-perl \
&& rm -rf /var/lib/apt/lists/*

RUN mkdir -p /var/www/nabovarme/cache
RUN mkdir -p /var/www/nabovarme/qr
RUN chown www-data:www-data /var/www/nabovarme/cache
RUN chown www-data:www-data /var/www/nabovarme/qr

RUN a2enmod expires
RUN a2enmod remoteip
RUN a2enmod headers

COPY ./htdocs /var/www/nabovarme
COPY ./000-default.conf /etc/apache2/sites-available/

COPY ./perl /etc/apache2/perl
COPY ./docker-entrypoint.sh /docker-entrypoint.sh
COPY ./template.tex /var/www/nabovarme/qr/

COPY ./update_meters.pl /etc/apache2/perl/Nabovarme/bin/update_meters.pl
COPY ./clean_samples_cache.pl /etc/apache2/perl/Nabovarme/bin/clean_samples_cache.pl

# Symlink Apache logs to stdout/stderr for Docker log visibility
RUN ln -sf /dev/stdout /var/log/apache2/access.log \
	&& ln -sf /dev/stderr /var/log/apache2/error.log

ENV PERL5LIB=/etc/apache2/perl

CMD ["/docker-entrypoint.sh"]
