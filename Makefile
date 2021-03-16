all: build up

build:
	docker-compose build

up:
	docker network create meterlogger
	docker-compose up -d

log:
	docker-compose logs -f

down:
	docker-compose down
	docker network rm meterlogger
top:
	docker stats db mqtt web meter_grapher mysql_mqtt_command_queue_receive mysql_mqtt_command_queue_send smsd meter_sms meter_cron redis postfix
