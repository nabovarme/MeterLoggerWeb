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
	libdbd-mysql-perl \
	libdbi-perl \
	libconfig-simple-perl \
	libcurses-perl \
	libemail-mime-perl \
	default-mysql-client \
	software-properties-common \
	texlive \
	texlive-latex-base \
	texlive-latex-extra \
	texlive-fonts-extra \
	qrencode \
	imagemagick \
	pbzip2 \
	locales

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

USER root

# Enable en_US.UTF-8 locale
RUN sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && \
	locale-gen

# Set UTF-8 locale environment variables
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

# Create user
RUN useradd -ms /bin/bash meterlogger

# Allow passwordless sudo for meterlogger
RUN echo "meterlogger ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/meterlogger && \
	chmod 0440 /etc/sudoers.d/meterlogger

# Copy entrypoint script
COPY ./utils/docker-entrypoint.sh /docker-entrypoint.sh

USER meterlogger
WORKDIR /home/meterlogger

RUN echo 'shopt -s histappend' >> /home/meterlogger/.bashrc && \
	echo 'PROMPT_COMMAND="history -a; history -n; $PROMPT_COMMAND"' >> /home/meterlogger/.bashrc && \
	echo 'export HISTFILE=/home/meterlogger/.bash_history' >> /home/meterlogger/.bashrc && \
	echo 'export HISTSIZE=1000000' >> /home/meterlogger/.bashrc && \
	echo 'export HISTFILESIZE=1000000' >> /home/meterlogger/.bashrc

# Copy application scripts
COPY ./perl perl
COPY ./utils/mqtt_log_all.pl mqtt_log_all.pl
COPY ./utils/smstools_send.pl smstools_send.pl
COPY ./utils/run_backup.sh run_backup.sh
COPY ./utils/mqtt_send.pl mqtt_send.pl
COPY ./utils/find_alternative_ssid.pl find_alternative_ssid.pl
COPY ./utils/mesh_topology.pl mesh_topology.pl

ENV PERL5LIB=/home/meterlogger/perl:${PERL5LIB}

CMD /docker-entrypoint.sh
