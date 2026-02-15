FROM debian:bullseye

LABEL maintainer="Kristoffer Ek <stoffer@skulp.net>"

RUN apt-get update && apt-get install -y \
	aptitude \
	autoconf \
	automake \
	aptitude \
	bash \
	bison \
	cpanplus \
	flex \
	g++ \
	gawk \
	gcc \
	git \
	inetutils-telnet \
	joe \
	make \
	sed \
	texinfo \
	sudo \
	screen \
	rsync \
	apache2 \
	apache2-bin \
	apache2-doc \
	apache2-utils \
	libapache2-mod-perl2 \
	libapache2-mod-perl2-dev \
	libapache2-mod-perl2-doc \
	libembperl-perl \
	libdbd-mysql-perl \
	libdbi-perl \
	libconfig-simple-perl \
	libtime-duration-perl \
	libjson-xs-perl \
	libemail-mime-perl \
	default-mysql-client\
	software-properties-common \
	texlive \
	texlive-latex-base \
	texlive-latex-extra \
	texlive-fonts-extra \
	qrencode \
	imagemagick \
	curl

# Copy local repository from Docker volume
RUN mkdir -p /opt/local-debs
COPY ./perl_modules/debs/*.deb /opt/local-debs

# Install all local .deb packages
RUN for pkg in /opt/local-debs/*.deb; do \
		echo "Installing $pkg..."; \
		dpkg -i --force-overwrite "$pkg" || true; \
	done

# Fix any missing dependencies from official repos
RUN apt-get update && \
	apt-get -f install -y

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

ENV PERL5LIB=/etc/apache2/perl:${PERL5LIB}

CMD /docker-entrypoint.sh
