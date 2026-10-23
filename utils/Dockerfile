# utils/Dockerfile
FROM perl-base:1.0

LABEL maintainer="Kristoffer Ek <stoffer@skulp.net>"

RUN apt-get update && apt-get install -y --no-install-recommends \
	pbzip2 \
	docker.io \
	util-linux \
	&& rm -rf /var/lib/apt/lists/*

# Set UTF-8 locale environment variables
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

# Create user with a dedicated UID/GID
RUN groupadd -g 1000 meterlogger && \
    useradd -u 1000 -g 1000 -ms /bin/bash meterlogger

# Allow passwordless sudo for meterlogger
RUN echo "meterlogger ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/meterlogger && \
	chmod 0440 /etc/sudoers.d/meterlogger

# Copy the toolchain and the firmware source code from the SDK image[cite: 1]
COPY --chown=meterlogger:meterlogger --from=firmware_sdk:latest /meterlogger /meterlogger

# Set up the environment variables required by the SDK[cite: 1]
ENV XTENSA_TOOLS_ROOT="/meterlogger/esp-open-sdk/xtensa-lx106-elf/bin"
ENV SDK_BASE="/meterlogger/esp-open-sdk/sdk"

WORKDIR /home/meterlogger

# Add Xtensa tools and /home/meterlogger to system PATH[cite: 1]
ENV PATH="/meterlogger/esp-open-sdk/xtensa-lx106-elf/bin:/home/meterlogger:${PATH}"

RUN echo 'shopt -s histappend' >> /home/meterlogger/.bashrc && \
	echo 'PROMPT_COMMAND="history -a; history -n; $PROMPT_COMMAND"' >> /home/meterlogger/.bashrc && \
	echo 'export HISTFILE=/home/meterlogger/.bash_history' >> /home/meterlogger/.bashrc && \
	echo 'export HISTSIZE=1000000' >> /home/meterlogger/.bashrc && \
	echo 'export HISTFILESIZE=1000000' >> /home/meterlogger/.bashrc

# Copy application scripts
COPY --chown=meterlogger:meterlogger ./perl perl
COPY --chown=meterlogger:meterlogger ./utils/mqtt_log_all.pl mqtt_log_all.pl
COPY --chown=meterlogger:meterlogger ./utils/smstools_send.pl smstools_send.pl
COPY --chown=meterlogger:meterlogger ./utils/run_backup.sh run_backup.sh
COPY --chown=meterlogger:meterlogger ./utils/mqtt_send.pl mqtt_send.pl
COPY --chown=meterlogger:meterlogger ./utils/mqtt_queue_send.pl mqtt_queue_send.pl
COPY --chown=meterlogger:meterlogger ./utils/find_alternative_ssid.pl find_alternative_ssid.pl
COPY --chown=meterlogger:meterlogger ./utils/mesh_topology.pl mesh_topology.pl
COPY --chown=meterlogger:meterlogger ./utils/generate_vapid_keys.pl generate_vapid_keys.pl
COPY --chown=meterlogger:meterlogger ./utils/push_send.pl push_send.pl
COPY --chown=meterlogger:meterlogger ./utils/ota_update.pl ota_update.pl
COPY --chown=meterlogger:meterlogger ./utils/build_firmware.pl build_firmware.pl
COPY --chown=meterlogger:meterlogger ./utils/meter_simulator.pl meter_simulator.pl
COPY --chown=meterlogger:meterlogger ./utils/unwind_crash.pl unwind_crash.pl
COPY --chown=meterlogger:meterlogger ./utils/set_key.pl set_key.pl

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
	echo 'alias ota_update="perl /home/meterlogger/ota_update.pl"' >> /home/meterlogger/.bashrc && \
	echo 'alias build_firmware="perl /home/meterlogger/build_firmware.pl"' >> /home/meterlogger/.bashrc && \
	echo 'alias meter_simulator="perl /home/meterlogger/meter_simulator.pl"' >> /home/meterlogger/.bashrc && \
	echo 'alias unwind_crash="perl /home/meterlogger/unwind_crash.pl"' >> /home/meterlogger/.bashrc && \
	echo 'alias set_key="perl /home/meterlogger/set_key.pl"' >> /home/meterlogger/.bashrc

# =========================================================================
# Version Tracking Setup
# =========================================================================
ARG GIT_COMMIT=unknown
ENV GIT_COMMIT=${GIT_COMMIT}
LABEL app.git.commit=${GIT_COMMIT}

# Ensure everything belongs to the meterlogger user
RUN chown -R meterlogger:meterlogger /home/meterlogger

# Copy and prepare entrypoint
COPY --chown=meterlogger:meterlogger ./utils/docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

# Default to meterlogger. This makes 'docker exec' land as meterlogger automatically!
USER meterlogger

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["/bin/bash", "-c", "while true; do sleep 1; done"]
