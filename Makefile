# ==============================================================================
# MING Stack Makefile
# ==============================================================================

.PHONY: help up down restart logs ps clean pull status interactive start stop \
        test-mqtt test-sandbox buckets

# Colors
GREEN  := \033[0;32m
YELLOW := \033[1;33m
CYAN   := \033[0;36m
RED    := \033[0;31m
BOLD   := \033[1m
DIM    := \033[2m
NC     := \033[0m

# Service list
MING_SERVICES := mqtt influxdb node-red grafana

# Default target
help:
	@echo ""
	@printf "$(BOLD)$(CYAN)  MING Stack$(NC) - Available Commands\n"
	@echo "  ════════════════════════════════════════════"
	@echo ""
	@printf "  $(BOLD)Core:$(NC)\n"
	@printf "    $(GREEN)make up$(NC)              Start all services\n"
	@printf "    $(GREEN)make down$(NC)            Stop all services\n"
	@printf "    $(GREEN)make restart$(NC)         Restart all services\n"
	@printf "    $(GREEN)make status$(NC)          Show service status table\n"
	@printf "    $(GREEN)make logs$(NC)            Follow logs for all services\n"
	@printf "    $(GREEN)make ps$(NC)              Docker compose ps\n"
	@printf "    $(GREEN)make pull$(NC)            Pull latest images\n"
	@printf "    $(GREEN)make clean$(NC)           Stop and remove volumes\n"
	@echo ""
	@printf "  $(BOLD)Modular:$(NC)\n"
	@printf "    $(GREEN)make interactive$(NC)     Interactive service selector\n"
	@printf "    $(GREEN)make start SERVICE=x$(NC) Start a service + its deps\n"
	@printf "    $(GREEN)make stop SERVICE=x$(NC)  Stop a service (warns about deps)\n"
	@echo ""
	@printf "  $(BOLD)InfluxDB:$(NC)\n"
	@printf "    $(GREEN)make buckets$(NC)         List all InfluxDB buckets\n"
	@echo ""
	@printf "  $(BOLD)Testing:$(NC)\n"
	@printf "    $(GREEN)make test-mqtt$(NC)       Publish test data to MQTT\n"
	@printf "    $(GREEN)make test-sandbox$(NC)    Publish test data to sandbox bucket\n"
	@echo ""

# ------------------------------------------------------------------------------
# Core Commands
# ------------------------------------------------------------------------------

up:
	@echo "Starting MING stack..."
	docker compose up -d
	@echo ""
	@echo "Services started! Access them at:"
	@printf "  $(CYAN)Grafana$(NC):   http://localhost:3000\n"
	@printf "  $(CYAN)Node-RED$(NC):  http://localhost:1880\n"
	@printf "  $(CYAN)InfluxDB$(NC):  http://localhost:8086\n"
	@echo ""

down:
	@echo "Stopping MING stack..."
	docker compose down

restart:
	@echo "Restarting MING stack..."
	docker compose restart

logs:
	docker compose logs -f

ps:
	docker compose ps

pull:
	@echo "Pulling latest images..."
	docker compose pull

clean:
	@printf "$(RED)$(BOLD)  WARNING: This will DELETE ALL DATA (InfluxDB, Grafana, etc.)$(NC)\n"
	@read -p "  Type 'yes' to confirm: " confirm; \
	if [ "$$confirm" = "yes" ]; then \
		echo "Stopping services and removing volumes..."; \
		docker compose down -v; \
		echo "Cleaned up!"; \
	else \
		echo "Cancelled."; \
	fi

# ------------------------------------------------------------------------------
# Status (colorized service table)
# ------------------------------------------------------------------------------

status:
	@echo ""
	@printf "$(BOLD)$(CYAN)  MING Stack - Service Status$(NC)\n"
	@echo "  ════════════════════════════════════════════════════════════════════"
	@printf "  $(BOLD)%-14s %-12s %-8s %s$(NC)\n" "SERVICE" "STATUS" "PORT" "URL"
	@printf "  $(DIM)%-14s %-12s %-8s %s$(NC)\n" "─────────────" "──────────" "──────" "───────────────────────────"
	@for svc in mqtt influxdb node-red grafana; do \
		container="p4n4-$$svc"; \
		state=$$(docker inspect --format='{{.State.Status}}' $$container 2>/dev/null || echo "stopped"); \
		case $$svc in \
			mqtt)      port="1883"; url="-" ;; \
			influxdb)  port="8086"; url="http://localhost:8086" ;; \
			node-red)  port="1880"; url="http://localhost:1880" ;; \
			grafana)   port="3000"; url="http://localhost:3000" ;; \
		esac; \
		if [ "$$state" = "running" ]; then \
			printf "  $(BOLD)%-14s$(NC) $(GREEN)%-12s$(NC) %-8s %s\n" "$$svc" "running" "$$port" "$$url"; \
		else \
			printf "  $(BOLD)%-14s$(NC) $(RED)%-12s$(NC) %-8s $(DIM)%s$(NC)\n" "$$svc" "$$state" "$$port" "-"; \
		fi; \
	done
	@echo ""

# ------------------------------------------------------------------------------
# Interactive Service Selector
# ------------------------------------------------------------------------------

interactive:
	@bash scripts/selector.sh

# ------------------------------------------------------------------------------
# Granular Start/Stop with Dependency Awareness
# ------------------------------------------------------------------------------

# Dependency map
deps_mqtt :=
deps_influxdb :=
deps_node-red := mqtt influxdb
deps_grafana := influxdb

# Reverse deps (what breaks)
rdeps_mqtt := node-red
rdeps_influxdb := node-red grafana
rdeps_node-red :=
rdeps_grafana :=

start:
ifndef SERVICE
	@printf "$(RED)  Usage: make start SERVICE=<name>$(NC)\n"
	@printf "  Available: $(BOLD)mqtt influxdb node-red grafana$(NC)\n"
	@exit 1
endif
	@deps="$(deps_$(SERVICE))"; \
	if [ -n "$$deps" ]; then \
		printf "$(YELLOW)  Auto-starting dependencies: $(BOLD)$$deps$(NC)\n"; \
		docker compose up -d $$deps; \
	fi
	@printf "$(GREEN)  Starting $(BOLD)$(SERVICE)$(NC)$(GREEN)...$(NC)\n"
	@docker compose up -d $(SERVICE)
	@printf "$(GREEN)$(BOLD)  Done!$(NC)\n"

stop:
ifndef SERVICE
	@printf "$(RED)  Usage: make stop SERVICE=<name>$(NC)\n"
	@printf "  Available: $(BOLD)mqtt influxdb node-red grafana$(NC)\n"
	@exit 1
endif
	@rdeps="$(rdeps_$(SERVICE))"; \
	if [ -n "$$rdeps" ]; then \
		for dep in $$rdeps; do \
			state=$$(docker inspect --format='{{.State.Status}}' "p4n4-$$dep" 2>/dev/null || echo "stopped"); \
			if [ "$$state" = "running" ]; then \
				printf "$(RED)  WARNING: Stopping '$(SERVICE)' will affect running service: $(BOLD)$$dep$(NC)\n"; \
			fi; \
		done; \
	fi
	@printf "$(YELLOW)  Stopping $(BOLD)$(SERVICE)$(NC)$(YELLOW)...$(NC)\n"
	@docker compose stop $(SERVICE)
	@printf "$(GREEN)$(BOLD)  Done!$(NC)\n"

# ------------------------------------------------------------------------------
# InfluxDB Bucket Inspection
# ------------------------------------------------------------------------------

buckets:
	@printf "$(BOLD)$(CYAN)  InfluxDB Buckets$(NC)\n"
	@docker exec p4n4-influxdb influx bucket list \
		--token "$$(docker exec p4n4-influxdb sh -c 'echo $$DOCKER_INFLUXDB_INIT_ADMIN_TOKEN')" \
		--org "$$(docker exec p4n4-influxdb sh -c 'echo $$DOCKER_INFLUXDB_INIT_ORG')" 2>/dev/null \
		|| printf "$(RED)  InfluxDB is not running. Start with: make up$(NC)\n"

# ------------------------------------------------------------------------------
# Testing Commands
# ------------------------------------------------------------------------------

test-mqtt:
	@echo "Publishing test sensor data to MQTT..."
	docker run --rm --network p4n4-net eclipse-mosquitto:2 \
		mosquitto_pub -h mqtt -t 'sensors/test-sensor/temperature' \
		-m '{"value": 23.5, "unit": "C"}'
	@echo "Publishing test inference result..."
	docker run --rm --network p4n4-net eclipse-mosquitto:2 \
		mosquitto_pub -h mqtt -t 'inference/test-sensor/result' \
		-m '{"model": "test", "label": "idle", "confidence": 0.95, "latency": 25.3}'
	@echo "Done! Check Node-RED debug panel."

test-sandbox:
	@printf "$(CYAN)  Publishing test data to sandbox bucket...$(NC)\n"
	@docker run --rm --network p4n4-net eclipse-mosquitto:2 \
		mosquitto_pub -h mqtt -t 'sandbox/sensors/sandbox-sensor-1/temperature' \
		-m '{"value": 22.1, "unit": "C", "sandbox": true}'
	@docker run --rm --network p4n4-net eclipse-mosquitto:2 \
		mosquitto_pub -h mqtt -t 'sandbox/sensors/sandbox-sensor-1/humidity' \
		-m '{"value": 65.3, "unit": "%", "sandbox": true}'
	@docker run --rm --network p4n4-net eclipse-mosquitto:2 \
		mosquitto_pub -h mqtt -t 'sandbox/inference/sandbox-sensor-1/result' \
		-m '{"model": "sandbox-test", "label": "anomaly", "confidence": 0.87, "latency": 18.5, "sandbox": true}'
	@printf "$(GREEN)  Sandbox test data published!$(NC)\n"
	@printf "$(DIM)  View in Grafana using the 'InfluxDB-Sandbox' datasource.$(NC)\n"
