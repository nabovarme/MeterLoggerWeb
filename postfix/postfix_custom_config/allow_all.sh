#!/bin/bash

postconf -e 'smtpd_recipient_restrictions = check_sender_access lmdb:/etc/postfix/allowed_senders, reject'
postconf -e 'smtpd_helo_restrictions = permit_mynetworks'
postconf -e "queue_run_delay = 10s"
postconf -e "minimal_backoff_time = 10s"
postconf -e "maximal_backoff_time = 60s"
postconf -e "default_destination_rate_delay = 10s"
