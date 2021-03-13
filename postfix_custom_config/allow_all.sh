#!/bin/bash

postconf -e 'smtpd_recipient_restrictions = check_sender_access lmdb:/etc/postfix/allowed_senders, reject'
postconf -e 'smtpd_helo_restrictions = permit_mynetworks'
