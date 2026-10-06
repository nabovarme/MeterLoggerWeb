# Ensure bash_history file exists before build
BASH_HISTORY_FILE=./utils/bash_history

# Default target
all: build up

# Build target: build perl_base first (relied on by other images), then build all other services
build: $(BASH_HISTORY_FILE)
	@echo "Building perl_base..."
	docker compose build perl_base
	@echo "Building remaining services..."
	docker compose build

# Start all services
up:
	@echo "Starting all services..."
	docker compose up -d

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
	docker stats

# Enter an interactive firmware build environment for manual compilation and debugging
build-env:
	@echo "Starting interactive firmware SDK environment..."
	@echo "Tip: Run 'cd /meterlogger/MeterLogger && SERIAL=9999999 KEY=d7d1716fb13d5c88bc731366e7f17c94 AP=1 THERMO_NO=0 DEBUG_STACK_TRACE=1 make clean all' inside."
	docker compose run --rm --entrypoint bash firmware_sdk

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
	docker compose up -d --no-deps $(filter-out $@,$(MAKECMDGOALS))

# Prevent make from treating service names as targets
%:
	@:
