#!/usr/bin/env bash

mysql -h 127.0.0.1 -u root -p$MYSQL_ROOT_PASSWORD nabovarme < /nabovarme.sql &&

echo "GRANT SELECT,INSERT,UPDATE,DELETE ON root.* TO '*'@'%' IDENTIFIED BY '$MYSQL_PASSWORD'" | mysql -h 127.0.0.1 -u root -p$MYSQL_ROOT_PASSWORD &&
echo "GRANT SELECT,INSERT,UPDATE,DELETE ON nabovarme.* TO 'nabovarme'@'%' IDENTIFIED BY '$MYSQL_PASSWORD'" | mysql -h 127.0.0.1 -u root -p$MYSQL_ROOT_PASSWORD &&

echo "FLUSH PRIVILEGES" | mysql -h 127.0.0.1 -u root -p$MYSQL_ROOT_PASSWORD

mysql_upgrade -h 127.0.0.1 -u root -p$MYSQL_ROOT_PASSWORD

echo "import existing db by running:
	docker cp mysql_backup.sql.bz2 db:/tmp/	
	docker exec -it db /nabovarme_import.sh
	docker exec -it db /nabovarme_triggers.sh"
