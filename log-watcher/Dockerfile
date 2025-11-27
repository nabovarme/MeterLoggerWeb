FROM debian:stable

# Install Perl, uhubctl, USB lib
RUN apt-get update && apt-get install -y \
	perl \
	libnet-smtp-ssl-perl \
	ca-certificates \
	uhubctl \
	libusb-1.0-0 \
	curl

# -------------------------------
# Install portable static Docker CLI
# -------------------------------

ENV DOCKER_VERSION=27.3.1

RUN ARCH=$(dpkg --print-architecture | sed 's/amd64/x86_64/;s/arm64/aarch64/') \
	&& curl -SL https://download.docker.com/linux/static/stable/$ARCH/docker-$DOCKER_VERSION.tgz \
		 -o /tmp/docker.tgz \
	&& tar -xzf /tmp/docker.tgz -C /tmp \
	&& mv /tmp/docker/* /usr/local/bin/ \
	&& chmod +x /usr/local/bin/docker* \
	&& rm -rf /tmp/docker*

# -------------------------------
# Install docker compose plugin
# -------------------------------

ENV COMPOSE_VERSION=2.29.7

RUN ARCH=$(dpkg --print-architecture | sed 's/amd64/x86_64/;s/arm64/aarch64/') \
	&& mkdir -p /usr/local/lib/docker/cli-plugins \
	&& curl -SL https://github.com/docker/compose/releases/download/v$COMPOSE_VERSION/docker-compose-linux-$ARCH \
		 -o /usr/local/lib/docker/cli-plugins/docker-compose \
	&& chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

# Verify install
RUN docker --version && docker compose version

# Copy watcher script
COPY watcher.pl /watcher.pl
RUN chmod +x /watcher.pl

WORKDIR /

CMD ["/watcher.pl"]
