# Use Debian Bullseye
FROM debian:bullseye

LABEL maintainer="Kristoffer Ek <stoffer@skulp.net>"

# Install Perl runtime libraries and build tools
RUN apt-get update && apt-get install -y \
	libtest-warn-perl \
	libtest-sharedfork-perl \
	libtest2-perl \
	libnumber-format-perl \
	build-essential \
	devscripts \
	fakeroot \
	dh-make-perl \
	cpanminus \
	wget \
	git \
	joe \
	aptitude \
	&& apt-get clean \
	&& rm -rf /var/lib/apt/lists/*

RUN PERL_MM_USE_DEFAULT=1 cpan install Test2::V0
RUN PERL_MM_USE_DEFAULT=1 cpan install Test::Deep
RUN PERL_MM_USE_DEFAULT=1 cpan install Math::Random::ISAAC
RUN PERL_MM_USE_DEFAULT=1 cpan install Crypt::Random::Source::Factory
RUN PERL_MM_USE_DEFAULT=1 cpan install JSON::Create
RUN PERL_MM_USE_DEFAULT=1 cpan install IO::Socket::Timeout

# Set working directory for building
WORKDIR /build

# Copy build script
COPY ./perl_modules/build-all.sh  /build/build-all.sh
RUN chmod +x /build/build-all.sh

# Default command
CMD ["/build/build-all.sh"]
