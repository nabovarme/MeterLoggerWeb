#!/bin/bash

#mysqldump --single-transaction --skip-add-drop-table --no-create-info nabovarme | pbzip2 > /var/lib/mysql_backup.sql.bz2
mysqldump -h $(METERLOGGER_DB_HOST) -u $(METERLOGGER_DB_USER) -p $(METERLOGGER_DB_PASSWORD) --single-transaction nabovarme | pbzip2 > mysql_backup.sql.bz2
if [ "${PIPESTATUS[0]}" -eq "0" ]
then
	echo "dump worked"
#	ssh elprog "rsync -av mysql_backup.sql.bz2 mysql_backup_`date +'%d_%m_%Y'`.sql.bz2"
#	rsync -azxv --partial --progress --stats \
#		/var/lib/mysql_backup.sql.bz2 \
#		elprog:

#	rsync -azxv --partial --progress --stats --delete \
#		--exclude='/var/lib/mysql/' \
#		--exclude='/root/.ssh/' \
#		--exclude='/etc/network/interfaces' \
#		--exclude='/etc/resolv.conf' \
#		--exclude='/etc/openvpn/' \
#		--exclude='/etc/hostname' \
#		--exclude='/etc/hosts' \
#		--exclude='/tmp/' \
#		--exclude='/etc/crontab' \
#		/ \
#		nabovarme2:/ &&
#	ssh nabovarme2 'bzcat /var/lib/mysql_backup.sql.bz2 | mysql'
else
    echo "dump failed"
fi
