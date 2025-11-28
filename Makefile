all: build up

# Ensure bash_history file exists before build
BASH_HISTORY_FILE=./utils/bash_history

build: $(BASH_HISTORY_FILE)
	docker compose build

up:
	docker compose up -d

log:
	docker compose logs -f

down:
	docker compose down

top:
	docker stats db mqtt web meter_grapher mysql_mqtt_command_queue_receive mysql_mqtt_command_queue_send smsd meter_sms meter_cron redis postfix

# Automatically create bash_history file if missing
$(BASH_HISTORY_FILE):
	@mkdir -p ./utils
	@touch $(BASH_HISTORY_FILE)
	@echo "Created $(BASH_HISTORY_FILE) if it did not exist"
