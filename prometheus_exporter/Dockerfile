# prometheus_exporter

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

# --- Enable required Apache modules ---
RUN a2enmod perl \
	&& a2enmod headers \
	&& a2enmod rewrite

# --- Copy local perl libs ---
COPY ./perl /etc/apache2/perl

# --- Copy Apache config ---
COPY ./prometheus_exporter/000-default.conf /etc/apache2/sites-available/000-default.conf

# --- Environment ---
ENV PERL5LIB=/etc/apache2/perl

# --- Logs to Docker stdout/stderr ---
RUN ln -sf /dev/stdout /var/log/apache2/access.log \
	&& ln -sf /dev/stderr /var/log/apache2/error.log

# --- Permissions ---
RUN chown -R www-data:www-data /etc/apache2/perl

# --- Expose HTTP ---
EXPOSE 80

# --- Start Apache in foreground ---
CMD ["/usr/sbin/apache2ctl", "-D", "FOREGROUND"]
