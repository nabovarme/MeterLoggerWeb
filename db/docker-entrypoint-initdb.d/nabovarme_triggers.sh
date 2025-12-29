#!/usr/bin/env bash

mysql -h 127.0.0.1 -u root -p$MYSQL_ROOT_PASSWORD nabovarme < /docker-entrypoint-initdb.d/nabovarme.sql
