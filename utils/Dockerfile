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

# Add /home/meterlogger to system PATH
ENV PATH="/home/meterlogger:${PATH}"

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
COPY ./utils/mqtt_queue_send.pl mqtt_queue_send.pl
COPY ./utils/find_alternative_ssid.pl find_alternative_ssid.pl
COPY ./utils/mesh_topology.pl mesh_topology.pl
COPY ./utils/generate_vapid_keys.pl generate_vapid_keys.pl
COPY ./utils/push_send.pl push_send.pl
COPY ./utils/ota_update.pl ota_update.pl

ENV PERL5LIB=/home/meterlogger/perl

# Add aliases for Perl scripts without the .pl suffix
RUN echo 'alias mqtt_log_all="perl /home/meterlogger/mqtt_log_all.pl"' >> /home/meterlogger/.bashrc && \
	echo 'alias smstools_send="perl /home/meterlogger/smstools_send.pl"' >> /home/meterlogger/.bashrc && \
	echo 'alias mqtt_send="perl /home/meterlogger/mqtt_send.pl"' >> /home/meterlogger/.bashrc && \
	echo 'alias mqtt_queue_send="perl /home/meterlogger/mqtt_queue_send.pl"' >> /home/meterlogger/.bashrc && \
	echo 'alias find_alternative_ssid="perl /home/meterlogger/find_alternative_ssid.pl"' >> /home/meterlogger/.bashrc && \
	echo 'alias mesh_topology="perl /home/meterlogger/mesh_topology.pl"' >> /home/meterlogger/.bashrc && \
	echo 'alias generate_vapid_keys="perl /home/meterlogger/generate_vapid_keys.pl"' >> /home/meterlogger/.bashrc && \
	echo 'alias push_send="perl /home/meterlogger/push_send.pl"' >> /home/meterlogger/.bashrc && \
	echo 'alias ota_update="perl /home/meterlogger/ota_update.pl"' >> /home/meterlogger/.bashrc

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
