# MeterLoggerWeb

MeterLoggerWeb is the backend system for MeterLogger

## Build details

docker-compose up --build

To initialize db (only do it first time!):

docker exec -it db /nabovarme_setup.sh

docker cp mysql_backup.sql.bz2 db:/tmp/

docker exec -it db /nabovarme_import.sh

docker exec -it db /nabovarme_triggers.sh
