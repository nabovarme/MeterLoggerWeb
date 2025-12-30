# Ensure bash_history file exists before build
BASH_HISTORY_FILE=./utils/bash_history

# All services
ALL_SERVICES=perl_modules_builder db mqtt web meter_grapher mysql_mqtt_command_queue_receive mysql_mqtt_command_queue_send smsd meter_sms meter_cron redis postfix
OTHER_SERVICES=$(filter-out perl_modules_builder,$(ALL_SERVICES))

# Default target
all: build up

# Build target: build and run perl_modules_builder first, then build other services
build: $(BASH_HISTORY_FILE)
	@echo "Building and starting perl_modules_builder..."
	docker compose build perl_modules_builder
	docker compose up -d perl_modules_builder
	@echo "Building remaining services..."
	docker compose build $(OTHER_SERVICES)

# Start all other services (after build)
up:
	@echo "Starting all other services..."
	docker compose up -d $(OTHER_SERVICES)

# Log a specific service
log:
	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		echo "Usage: make log <service>"; \
		exit 1; \
	fi
	docker compose logs -f $(filter-out $@,$(MAKECMDGOALS))

logs:
	docker compose logs -f

down:
	docker compose down

top:
	docker stats $(ALL_SERVICES)

# Automatically create bash_history file if missing
$(BASH_HISTORY_FILE):
	@mkdir -p ./utils
	@touch $(BASH_HISTORY_FILE)
	@echo "Created $(BASH_HISTORY_FILE) if it did not exist"

# Redeploy a specific service
redeploy:
	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		echo "Usage: make redeploy <service>"; \
		exit 1; \
	fi
	git pull
	docker compose build $(filter-out $@,$(MAKECMDGOALS))
	docker compose down $(filter-out $@,$(MAKECMDGOALS))
	docker compose up -d $(filter-out $@,$(MAKECMDGOALS))

# Prevent make from treating service names as targets
%:
	@:
