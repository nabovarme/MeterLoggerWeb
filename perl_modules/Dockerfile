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

RUN PERL_MM_USE_DEFAULT=1 cpanm Math::Random::Secure
RUN PERL_MM_USE_DEFAULT=1 cpanm Statistics::Basic
RUN PERL_MM_USE_DEFAULT=1 cpanm Time::Format
RUN PERL_MM_USE_DEFAULT=1 cpanm JSON
RUN PERL_MM_USE_DEFAULT=1 cpanm Cpanel::JSON::XS
RUN PERL_MM_USE_DEFAULT=1 cpanm Redis
RUN PERL_MM_USE_DEFAULT=1 cpanm File::chown
RUN PERL_MM_USE_DEFAULT=1 cpanm Test2::V0
RUN PERL_MM_USE_DEFAULT=1 cpanm Test::Deep
RUN PERL_MM_USE_DEFAULT=1 cpanm Math::Random::ISAAC
RUN PERL_MM_USE_DEFAULT=1 cpanm Crypt::Random::Source::Factory
RUN PERL_MM_USE_DEFAULT=1 cpanm IO::Socket::Timeout
RUN PERL_MM_USE_DEFAULT=1 cpanm Module::Find
RUN PERL_MM_USE_DEFAULT=1 cpanm PerlIO::via::Timeout
RUN PERL_MM_USE_DEFAULT=1 cpanm Number::Format
RUN PERL_MM_USE_DEFAULT=1 cpanm Exporter::Tiny
RUN PERL_MM_USE_DEFAULT=1 cpanm Type::Tiny
RUN PERL_MM_USE_DEFAULT=1 cpanm Types::Standard


# Set working directory for building
WORKDIR /build

# Copy build script
COPY ./perl_modules/build-all.sh  /build/build-all.sh
RUN chmod +x /build/build-all.sh

# Default command
CMD ["/build/build-all.sh"]
