FROM debian:bullseye

LABEL maintainer="Kristoffer Ek <stoffer@skulp.net>"

# --- Base system + Apache + mod_perl ---
RUN apt-get update && apt-get install -y \
	aptitude \
	autoconf \
	automake \
	bash \
	bison \
	flex \
	g++ \
	gawk \
	gcc \
	git \
	make \
	sed \
	joe \
	sudo \
	screen \
	rsync \
	curl \
	apache2 \
	apache2-bin \
	apache2-utils \
	libapache2-mod-perl2 \
	libapache2-mod-perl2-dev \
	libdbd-mysql-perl \
	libdbi-perl \
	libconfig-simple-perl \
	libjson-xs-perl \
	libemail-mime-perl \
	default-mysql-client

# --- Enable required Apache modules ---
RUN a2enmod perl \
	&& a2enmod headers \
	&& a2enmod rewrite

# --- Copy local perl libs ---
COPY ./perl /etc/apache2/perl

# --- Copy Apache config ---
COPY ./prometheus_exporter/000-default.conf /etc/apache2/sites-available/000-default.conf

# --- Optional local debs ---
RUN mkdir -p /opt/local-debs
COPY ./perl_modules/debs/*.deb /opt/local-debs/

RUN for pkg in /opt/local-debs/*.deb; do \
	echo "Installing $pkg..."; \
	dpkg -i --force-overwrite "$pkg" || true; \
	done

RUN apt-get update && apt-get -f install -y && rm -rf /var/lib/apt/lists/*

# --- Environment ---
ENV PERL5LIB=/etc/apache2/perl:${PERL5LIB}

# --- Logs to Docker stdout/stderr ---
RUN ln -sf /dev/stdout /var/log/apache2/access.log \
	&& ln -sf /dev/stderr /var/log/apache2/error.log

# --- Permissions ---
RUN chown -R www-data:www-data /etc/apache2/perl

# --- Expose HTTP ---
EXPOSE 80

# --- Start Apache in foreground ---
CMD ["/usr/sbin/apache2ctl", "-D", "FOREGROUND"]
