FROM boky/postfix:latest

ENV DEBIAN_FRONTEND="noninteractive"
RUN apt-get update && apt-get install -y \
		libcurses-perl \
		libemail-mime-perl \
		aptitude \
		joe

COPY ./delete_sms.pl /usr/local/bin/

RUN chmod +x /usr/local/bin/*

