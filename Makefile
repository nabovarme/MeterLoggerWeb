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
