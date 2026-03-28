FROM debian:bookworm

RUN apt-get update && apt-get install -y \
	aptitude \
	procps \
	perl \
	libwww-perl \
	libjson-perl \
	curl \
	joe

WORKDIR /app

COPY ./builder/watcher/watcher.pl .

CMD ["perl", "watcher.pl"]
