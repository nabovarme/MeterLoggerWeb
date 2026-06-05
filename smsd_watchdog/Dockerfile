# smsd_watchdog

FROM perl-base:1.0

# Copy watcher script
COPY ./perl /usr/local/lib/perl
COPY ./smsd_watchdog/watcher.pl /watcher.pl

RUN chmod +x /watcher.pl

WORKDIR /

ENV PERL5LIB=/usr/local/lib/perl

# =========================================================================
# Version Tracking Setup
# Configures structural labels visible directly to the cAdvisor API
# =========================================================================
ARG GIT_COMMIT=unknown
ENV GIT_COMMIT=${GIT_COMMIT}
LABEL app.git.commit=${GIT_COMMIT}

# Run the watcher script natively as PID 1
CMD ["perl", "/watcher.pl"]
