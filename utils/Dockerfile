# utils

FROM perl-base:1.0

LABEL maintainer="Kristoffer Ek <stoffer@skulp.net>"

RUN apt-get update && apt-get install -y --no-install-recommends \
	pbzip2

USER root

# Set UTF-8 locale environment variables
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

# Create user
RUN useradd -ms /bin/bash meterlogger

# Allow passwordless sudo for meterlogger
RUN echo "meterlogger ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/meterlogger && \
	chmod 0440 /etc/sudoers.d/meterlogger

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

ENV PERL5LIB=/home/meterlogger/perl

# Copy entrypoint script
COPY ./utils/docker-entrypoint.sh /docker-entrypoint.sh

# =========================================================================
# Version Tracking Setup
# Configures structural labels visible directly to the cAdvisor API
# =========================================================================
ARG GIT_COMMIT=unknown
ENV GIT_COMMIT=${GIT_COMMIT}
LABEL app.git.commit=${GIT_COMMIT}

CMD ["/docker-entrypoint.sh"]
