# mysql_mqtt_command_queue_receive

FROM perl-base:1.0

LABEL maintainer="Kristoffer Ek <stoffer@skulp.net>"

USER root

COPY ./perl /usr/local/lib/perl

COPY ./mysql_mqtt_command_queue_receive/mysql_mqtt_command_queue_receive.pl /usr/local/bin/mysql_mqtt_command_queue_receive.pl

ENV PERL5LIB=/usr/local/lib/perl

CMD ["/usr/local/bin/mysql_mqtt_command_queue_receive.pl"]

