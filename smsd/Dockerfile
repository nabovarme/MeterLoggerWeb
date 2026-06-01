# smsd

FROM perl-base:1.0

LABEL maintainer="Kristoffer Ek <stoffer@skulp.net>"

USER root

# Add smsd group and user
RUN groupadd -r smsd && useradd -r -g smsd -m -s /bin/bash smsd

# Copy scripts
COPY ./perl /usr/local/lib/perl

COPY ./smsd/smtp_server.pl /usr/local/bin/smtp_server.pl

ENV PERL5LIB=/usr/local/lib/perl

# =========================================================================
# Version Tracking Setup
# Configures structural labels visible directly to the cAdvisor API
# =========================================================================
ARG GIT_COMMIT=unknown
ENV GIT_COMMIT=${GIT_COMMIT}
LABEL app.git.commit=${GIT_COMMIT}

# Switch context to your unprivileged runtime daemon user account
USER smsd

# Run the Perl SMTP server natively as PID 1
CMD ["perl", "/usr/local/bin/smtp_server.pl"]
