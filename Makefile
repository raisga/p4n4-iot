# ==============================================================================
# MING Stack Makefile
# ==============================================================================

.PHONY: help up down restart logs ps clean pull status interactive start stop \
        test-mqtt test-sandbox buckets influx-init bridge-status mqtt-user \
        mqtt-user-delete backup restore

# Colors
GREEN  := \033[0;32m
YELLOW := \033[1;33m
CYAN   := \033[0;36m
RED    := \033[0;31m
BOLD   := \033[1m
DIM    := \033[2m
NC     := \033[0m

# Service list (each service is in a Compose profile of the same name)
SERVICES := mqtt influxdb node-red grafana telegraf loki alloy mqtt-ui

# Started when neither the environment nor .env sets COMPOSE_PROFILES
DEFAULT_PROFILES := mqtt,influxdb,node-red,grafana
ifeq ($(origin COMPOSE_PROFILES)$(shell grep -s '^COMPOSE_PROFILES=' .env),undefined)
export COMPOSE_PROFILES := $(DEFAULT_PROFILES)
endif

# down/clean also stop services started outside COMPOSE_PROFILES (make start)
ALL_PROFILES := --profile '*'

# Image for one-off helper containers (tar, mosquitto_passwd): already pulled
# for the broker, so backups and new MQTT accounts work offline
TOOLS_IMAGE := eclipse-mosquitto:2.0

# make backup writes here; make restore BACKUP=<dir> reads one
BACKUP_ROOT := backups

# Default target
help:
	@echo ""
	@printf "$(BOLD)$(CYAN)  MING Stack$(NC) - Available Commands\n"
	@echo "  ════════════════════════════════════════════"
	@echo ""
	@printf "  $(BOLD)Core:$(NC)\n"
	@printf "    $(GREEN)make up$(NC)              Start the services in COMPOSE_PROFILES\n"
	@printf "    $(GREEN)make down$(NC)            Stop all services\n"
	@printf "    $(GREEN)make restart$(NC)         Restart all services\n"
	@printf "    $(GREEN)make status$(NC)          Show service status table\n"
	@printf "    $(GREEN)make logs$(NC)            Follow logs (SERVICE=x for one)\n"
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
	@printf "    $(GREEN)make influx-init$(NC)     Create missing buckets and the rollup task\n"
	@echo ""
	@printf "  $(BOLD)MQTT:$(NC)\n"
	@printf "    $(GREEN)make bridge-status$(NC)   External broker bridge state\n"
	@printf "    $(GREEN)make mqtt-user NAME=x$(NC) Add a device login (or change its password)\n"
	@printf "    $(GREEN)make mqtt-user-delete NAME=x$(NC) Remove a device login\n"
	@echo ""
	@printf "  $(BOLD)Backup:$(NC)\n"
	@printf "    $(GREEN)make backup$(NC)          Back up InfluxDB, Grafana, Node-RED, Mosquitto\n"
	@printf "    $(GREEN)make restore BACKUP=d$(NC) Restore a backup directory\n"
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
	@$(MAKE) --no-print-directory status

down:
	@echo "Stopping MING stack..."
	docker compose $(ALL_PROFILES) down

restart:
	@echo "Restarting MING stack..."
	docker compose restart

logs:
	docker compose $(ALL_PROFILES) logs -f $(SERVICE)

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
		docker compose $(ALL_PROFILES) down -v; \
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
	@for svc in $(SERVICES); do \
		container="p4n4-$$svc"; \
		state=$$(docker inspect --format='{{.State.Status}}' $$container 2>/dev/null || echo "stopped"); \
		case $$svc in \
			mqtt)      cport=1884; scheme="" ;; \
			influxdb)  cport=8086; scheme=http ;; \
			node-red)  cport=1880; scheme=http ;; \
			grafana)   cport=3000; scheme=http ;; \
			mqtt-ui)   cport=80;   scheme=http ;; \
			*)         cport="";   scheme="" ;; \
		esac; \
		port=$$( [ -n "$$cport" ] && docker port $$container $$cport/tcp 2>/dev/null | head -1 | sed 's/.*://'); \
		port=$${port:--}; url="-"; \
		if [ -n "$$scheme" ] && [ "$$port" != "-" ]; then url="$$scheme://localhost:$$port"; fi; \
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
deps_telegraf :=
deps_loki :=
deps_alloy := loki
deps_mqtt-ui :=

# Reverse deps (what breaks)
rdeps_mqtt := node-red
rdeps_influxdb := node-red grafana
rdeps_node-red :=
rdeps_grafana :=
rdeps_telegraf :=
rdeps_loki := alloy
rdeps_alloy :=
rdeps_mqtt-ui :=

start:
ifndef SERVICE
	@printf "$(RED)  Usage: make start SERVICE=<name>$(NC)\n"
	@printf "  Available: $(BOLD)$(SERVICES)$(NC)\n"
	@exit 1
endif
	@deps="$(deps_$(SERVICE))"; \
	if [ -n "$$deps" ]; then \
		printf "$(YELLOW)  Auto-starting dependencies: $(BOLD)$$deps$(NC)\n"; \
		docker compose $(foreach d,$(deps_$(SERVICE)),--profile $(d)) up -d $$deps; \
	fi
	@printf "$(GREEN)  Starting $(BOLD)$(SERVICE)$(NC)$(GREEN)...$(NC)\n"
	@docker compose $(foreach d,$(deps_$(SERVICE)) $(SERVICE),--profile $(d)) up -d $(SERVICE)
	@printf "$(GREEN)$(BOLD)  Done!$(NC)\n"

stop:
ifndef SERVICE
	@printf "$(RED)  Usage: make stop SERVICE=<name>$(NC)\n"
	@printf "  Available: $(BOLD)$(SERVICES)$(NC)\n"
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
	@docker compose $(ALL_PROFILES) stop $(SERVICE)
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

# init-buckets.sh runs on InfluxDB's first start only; this runs it again, so
# an existing install gets new buckets and the hourly rollup task
influx-init:
	@docker exec p4n4-influxdb bash /docker-entrypoint-initdb.d/init-buckets.sh \
		|| { printf "$(RED)  InfluxDB is not running. Start with: make up$(NC)\n"; exit 1; }

# ------------------------------------------------------------------------------
# External Broker Bridge
# ------------------------------------------------------------------------------

# Mosquitto publishes the bridge state (1 = connected) as a retained message
bridge-status:
	@host=$$(docker exec p4n4-mqtt sh -c 'echo $$MQTT_REMOTE_HOST' 2>/dev/null) \
		|| { printf "$(RED)  MQTT broker is not running. Start with: make up$(NC)\n"; exit 1; }; \
	if [ -z "$$host" ]; then \
		printf "$(DIM)  Bridge disabled (MQTT_REMOTE_HOST is empty in .env)$(NC)\n"; exit 0; \
	fi; \
	state=$$(docker exec p4n4-mqtt mosquitto_sub -h localhost \
		-t '$$SYS/broker/connection/p4n4-remote/state' -C 1 -W 3 2>/dev/null); \
	if [ "$$state" = "1" ]; then \
		printf "  Bridge to $(BOLD)%s$(NC): $(GREEN)connected$(NC)\n" "$$host"; \
	else \
		printf "  Bridge to $(BOLD)%s$(NC): $(RED)not connected$(NC)\n" "$$host"; \
		printf "$(DIM)  See: docker logs p4n4-mqtt$(NC)\n"; exit 1; \
	fi

# Device logins in config/mosquitto/passwd (hashed), used once MQTT_USER and
# MQTT_PASSWORD are set in .env. The broker reads the file when it starts.
mqtt-user:
ifndef NAME
	@printf "$(RED)  Usage: make mqtt-user NAME=<name>$(NC)\n"; exit 1
endif
	@umask 077; touch config/mosquitto/passwd
	@docker run --rm -it --user "$$(id -u):$$(id -g)" -v "$(CURDIR)/config/mosquitto:/work" \
		$(TOOLS_IMAGE) mosquitto_passwd /work/passwd "$(NAME)"
	@if grep -q "^$(NAME):" config/mosquitto/passwd; then \
		printf "$(GREEN)  Saved login '$(NAME)'.$(NC) Apply it: $(BOLD)docker compose restart mqtt$(NC)\n"; \
	else \
		printf "$(RED)  Login '$(NAME)' was not saved.$(NC)\n"; exit 1; \
	fi

mqtt-user-delete:
ifndef NAME
	@printf "$(RED)  Usage: make mqtt-user-delete NAME=<name>$(NC)\n"; exit 1
endif
	@docker run --rm --user "$$(id -u):$$(id -g)" -v "$(CURDIR)/config/mosquitto:/work" \
		$(TOOLS_IMAGE) mosquitto_passwd -D /work/passwd "$(NAME)"
	@printf "$(GREEN)  Removed login '$(NAME)'.$(NC) Apply it: $(BOLD)docker compose restart mqtt$(NC)\n"

# ------------------------------------------------------------------------------
# Backup and Restore
# ------------------------------------------------------------------------------

# InfluxDB with its own backup (all buckets, users and tokens), the other data
# volumes as tar files (streamed out, so they belong to you, not root). Taken
# while the services run; services that aren't running are skipped. Loki's
# logs and .env are not included.
backup:
	@dir="$(BACKUP_ROOT)/$$(date +%Y%m%d-%H%M%S)"; mkdir -p "$$dir"; \
	printf "$(CYAN)  Backing up to $(BOLD)%s$(NC)\n" "$$dir"; \
	if [ "$$(docker inspect -f '{{.State.Running}}' p4n4-influxdb 2>/dev/null)" = true ]; then \
		docker exec p4n4-influxdb sh -c 'rm -rf /tmp/p4n4-backup && out=$$(influx backup /tmp/p4n4-backup -t "$$DOCKER_INFLUXDB_INIT_ADMIN_TOKEN" 2>&1) || { echo "$$out"; exit 1; }' \
			&& docker cp -q p4n4-influxdb:/tmp/p4n4-backup "$$dir/influxdb" \
			&& docker exec p4n4-influxdb rm -rf /tmp/p4n4-backup \
			&& printf "  influxdb   $(GREEN)ok$(NC)\n" || { printf "  influxdb   $(RED)failed$(NC)\n"; exit 1; }; \
	else printf "  influxdb   $(DIM)not running, skipped$(NC)\n"; fi; \
	for item in grafana:/var/lib/grafana node-red:/data mqtt:/mosquitto/data; do \
		svc=$${item%%:*}; path=$${item#*:}; \
		if [ "$$(docker inspect -f '{{.State.Running}}' p4n4-$$svc 2>/dev/null)" != true ]; then \
			printf "  %-10s $(DIM)not running, skipped$(NC)\n" "$$svc"; continue; \
		fi; \
		docker run --rm --volumes-from "p4n4-$$svc" --entrypoint tar $(TOOLS_IMAGE) \
			czf - -C "$$path" --exclude ./node_modules --exclude ./.npm --exclude ./settings.js . >"$$dir/$$svc.tar.gz" \
			&& printf "  %-10s $(GREEN)ok$(NC)\n" "$$svc" || { printf "  %-10s $(RED)failed$(NC)\n" "$$svc"; exit 1; }; \
	done; \
	printf "$(GREEN)  Done.$(NC) Restore with: make restore BACKUP=%s\n" "$$dir"

# Replaces the data of each service found in the backup. Use the .env the backup
# was taken with: InfluxDB's tokens come back from the backup.
restore:
ifndef BACKUP
	@printf "$(RED)  Usage: make restore BACKUP=$(BACKUP_ROOT)/<timestamp>$(NC)\n"; exit 1
endif
	@[ -d "$(BACKUP)" ] || { printf "$(RED)  No such backup: $(BACKUP)$(NC)\n"; exit 1; }
	@printf "$(RED)$(BOLD)  WARNING: This REPLACES the current data with $(BACKUP)$(NC)\n"
	@read -p "  Type 'yes' to confirm: " confirm; [ "$$confirm" = "yes" ] || { echo "Cancelled."; exit 1; }
	@if [ -d "$(BACKUP)/influxdb" ]; then \
		docker cp -q "$(BACKUP)/influxdb" p4n4-influxdb:/tmp/p4n4-restore \
			&& docker exec p4n4-influxdb sh -c 'out=$$(influx restore /tmp/p4n4-restore --full -t "$$DOCKER_INFLUXDB_INIT_ADMIN_TOKEN" 2>&1); rc=$$?; rm -rf /tmp/p4n4-restore; [ $$rc = 0 ] || echo "$$out"; exit $$rc' \
			&& printf "  influxdb   $(GREEN)restored$(NC)\n" \
			|| { printf "  influxdb   $(RED)failed (is it running? make start SERVICE=influxdb)$(NC)\n"; exit 1; }; \
	fi
	@for item in grafana:/var/lib/grafana node-red:/data mqtt:/mosquitto/data; do \
		svc=$${item%%:*}; path=$${item#*:}; \
		[ -f "$(BACKUP)/$$svc.tar.gz" ] || continue; \
		docker inspect "p4n4-$$svc" >/dev/null 2>&1 \
			|| { printf "  %-10s $(RED)no container: make start SERVICE=%s first$(NC)\n" "$$svc" "$$svc"; exit 1; }; \
		docker stop "p4n4-$$svc" >/dev/null; \
		docker run --rm -i --volumes-from "p4n4-$$svc" --entrypoint tar $(TOOLS_IMAGE) \
			xzf - -C "$$path" <"$(BACKUP)/$$svc.tar.gz" \
			&& printf "  %-10s $(GREEN)restored$(NC)\n" "$$svc" || printf "  %-10s $(RED)failed$(NC)\n" "$$svc"; \
		docker start "p4n4-$$svc" >/dev/null; \
	done
	@printf "$(GREEN)  Done.$(NC)\n"

# ------------------------------------------------------------------------------
# Testing Commands
# ------------------------------------------------------------------------------

# Published inside the broker container, on the internal listener: no login
# needed, whatever MQTT_PASSWORD says
MQTT_PUB := docker exec p4n4-mqtt mosquitto_pub -h localhost -p 1883

test-mqtt:
	@echo "Publishing test sensor data to MQTT..."
	$(MQTT_PUB) -t 'sensors/test-sensor/temperature' -m '{"value": 23.5, "unit": "C"}'
	$(MQTT_PUB) -t 'sensors/test-sensor/humidity' -m '61.2'
	@echo "Publishing test inference result..."
	$(MQTT_PUB) -t 'inference/test-sensor/result' \
		-m '{"model": "test", "label": "idle", "confidence": 0.95, "latency": 25.3}'
	@echo "Done! Check Node-RED debug panel."

test-sandbox:
	@printf "$(CYAN)  Publishing test data to sandbox bucket...$(NC)\n"
	@$(MQTT_PUB) -t 'sandbox/sensors/sandbox-sensor-1/temperature' \
		-m '{"value": 22.1, "unit": "C", "sandbox": true}'
	@$(MQTT_PUB) -t 'sandbox/sensors/sandbox-sensor-1/humidity' \
		-m '{"value": 65.3, "unit": "%", "sandbox": true}'
	@$(MQTT_PUB) -t 'sandbox/inference/sandbox-sensor-1/result' \
		-m '{"model": "sandbox-test", "label": "anomaly", "confidence": 0.87, "latency": 18.5, "sandbox": true}'
	@printf "$(GREEN)  Sandbox test data published!$(NC)\n"
	@printf "$(DIM)  View in Grafana using the 'InfluxDB-Sandbox' datasource.$(NC)\n"
