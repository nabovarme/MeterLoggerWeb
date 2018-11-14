#!/usr/bin/env bash

mysql -u root -p$MYSQL_ROOT_PASSWORD nabovarme < /nabovarme.sql &&

echo "GRANT SELECT,INSERT,UPDATE,DELETE ON nabovarme.* TO 'nabovarme'@'%' IDENTIFIED BY '$MYSQL_PASSWORD'" | mysql -u root -p$MYSQL_ROOT_PASSWORD &&

echo "FLUSH PRIVILEGES" | mysql -u root -p$MYSQL_ROOT_PASSWORD
