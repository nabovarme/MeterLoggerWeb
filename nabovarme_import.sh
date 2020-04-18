#!/usr/bin/env bash

SQL_FILE=/tmp/mysql_backup.sql.bz2

apt-get update
apt-get install -y pv
SQL_FILE_SIZE=$(wc -c $SQL_FILE)
cat $SQL_FILE | pv -s $SQL_FILE_SIZE | bzcat | mysql -h 127.0.0.1 -u root -p$MYSQL_ROOT_PASSWORD nabovarme
