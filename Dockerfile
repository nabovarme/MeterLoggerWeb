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
	# --- Frontend Dependency Manager ---
	nodejs \
	npm \
	&& rm -rf /var/lib/apt/lists/*

# --- Static Directories Pass ---
RUN mkdir -p /var/www/nabovarme/cache \
             /var/www/nabovarme/qr \
             /var/www/nabovarme/sms_spool \
             /var/www/.texmf-var \
             /var/www/.texlive2018 && \
    chown -R www-data:www-data /var/www

# =======================================================
# Switch user context to generate fonts safely
# =======================================================
USER www-data

RUN mktexpk --mfmode / --bdpi 600 --mag 1+0/600 --dpi 600 ecsx3583 && \
    mktexpk --mfmode / --bdpi 600 --mag 1+0/600 --dpi 600 ectt1095 && \
    mktexpk --mfmode / --bdpi 600 --mag 1+0/600 --dpi 600 ecss1095

# =======================================================
# Switch back to root for core configurations and copies
# =======================================================
USER root

RUN a2enmod expires
RUN a2enmod remoteip
RUN a2enmod headers

COPY ./htdocs /var/www/nabovarme

# --- Install & Update Node Dependencies ---
WORKDIR /tmp/npm_build
COPY ./package.json ./

# Cache-busting line: Pass a random string or timestamp here to force npm install to run
ARG CACHE_BUST=1
RUN npm install --no-package-lock && \
	mkdir -p /var/www/nabovarme/js && \
	cp node_modules/libphonenumber-js/bundle/libphonenumber-max.js /var/www/nabovarme/js/ && \
	rm -rf /tmp/npm_build
	
# Return to nabovarme web dir for the rest of your configurations
WORKDIR /var/www/nabovarme

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

ENTRYPOINT ["/docker-entrypoint.sh"]
