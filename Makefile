all: build up

build:
	docker compose build

up:
	docker compose up -d

log:
	docker compose logs -f

down:
	docker compose down
top:
	docker stats db mqtt web meter_grapher mysql_mqtt_command_queue_receive mysql_mqtt_command_queue_send smsd meter_sms meter_cron redis postfix

api-key:
	@echo "Recreating CrowdSec bouncer and updating API key..."
	@docker exec -i crowdsec cscli bouncers delete openresty-bouncer >/dev/null 2>&1 || true
	@OUTPUT=$$(docker exec -i crowdsec cscli bouncers add openresty-bouncer 2>&1); \
	NEW_API_KEY=$$(echo "$$OUTPUT" | awk 'found { if ($$1 != "") { print $$1; exit } } /API key for '\''openresty-bouncer'\''/ { found=1 }'); \
	if [ -z "$$NEW_API_KEY" ]; then \
		echo "Failed to extract API key. Output was:"; \
		echo "$$OUTPUT"; \
		exit 1; \
	fi; \
	echo "New API key: $$NEW_API_KEY"; \
	echo "CROWDSEC_BOUNCER_API_KEY=$$NEW_API_KEY" > .env.openresty-bouncer; \
	echo ".env.openresty-bouncer updated with new API key."; \
	echo "Restarting crowdsec container..."; \
	docker compose restart crowdsec