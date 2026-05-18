# mysql_mqtt_command_queue_send

FROM perl-base:1.0

LABEL maintainer="Kristoffer Ek <stoffer@skulp.net>"

USER root

COPY ./perl /usr/local/lib/perl

COPY ./mysql_mqtt_command_queue_send/mysql_mqtt_command_queue_send.pl /usr/local/bin/mysql_mqtt_command_queue_send.pl

ENV PERL5LIB=/usr/local/lib/perl

CMD ["/usr/local/bin/mysql_mqtt_command_queue_send.pl"]

