FROM boky/postfix:latest

ENV DEBIAN_FRONTEND="noninteractive"
RUN apt-get update && apt-get install -y \
		libcurses-perl \
		libemail-mime-perl \
		aptitude \
		sed \
		locales \
		joe

COPY ./smsqueue.pl /usr/local/bin/

RUN chmod +x /usr/local/bin/*

# Enable en_US.UTF-8 locale
RUN sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && \
	locale-gen

# Set UTF-8 locale environment variables
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8
