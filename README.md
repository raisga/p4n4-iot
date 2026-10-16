# p4n4-iot

> Dockerized **MING stack** — a proven open-source foundation for IoT data pipelines.

The MING stack (MQTT · InfluxDB · Node-RED · Grafana) packages a complete IoT data pipeline into a single `docker compose` setup. Devices publish sensor readings over MQTT, Node-RED routes and transforms data into InfluxDB, and Grafana visualizes everything in real time.

Part of the [p4n4](https://github.com/raisga/p4n4) platform — an EdgeAI + GenAI integration platform for IoT deployments.

---

## Table of Contents

- [Architecture](#architecture)
- [Stack Components](#stack-components)
- [Prerequisites](#prerequisites)
- [Getting Started](#getting-started)
- [Choosing Services](#choosing-services)
- [Project Structure](#project-structure)
- [InfluxDB Buckets](#influxdb-buckets)
- [MQTT Topic Convention](#mqtt-topic-convention)
- [External MQTT Broker](#external-mqtt-broker)
- [Node-RED Packages](#node-red-packages)
- [Logs](#logs)
- [Usage](#usage)
- [Backup and Restore](#backup-and-restore)
- [Ports and Network](#ports-and-network)
- [Default Credentials](#default-credentials)
- [Security Hardening](#security-hardening)
- [Local Overrides](#local-overrides)
- [Resources](#resources)
- [License](#license)

---

## Architecture

```
  [IoT Devices / Sensors]
           │
           ▼
        [MQTT]          ← Eclipse Mosquitto (message broker)
           │
           ▼
       [Node-RED]       ← workflow engine (route, transform, persist)
           │
           ▼
       [InfluxDB]       ← time-series database (multiple buckets)
           │
           ▼
        [Grafana]       ← dashboards & alerts
```

**Data flow:** IoT devices publish sensor readings to MQTT topics. Node-RED subscribes to those topics, applies any business logic or transformations, and writes the data to InfluxDB using the HTTP API. Grafana reads from InfluxDB to render real-time dashboards and fire alerts.

This stack is designed to run standalone or alongside [`p4n4-ai`](https://github.com/raisga/p4n4-ai) on a shared `p4n4-net` Docker bridge network, enabling Node-RED to call Ollama, Letta, and n8n for AI-augmented IoT workflows.

---

## Stack Components

| Service | Role | Description |
|---------|------|-------------|
| **[Eclipse Mosquitto](https://mosquitto.org/)** | Message Broker | Lightweight MQTT broker — the central nervous system of the IoT pipeline. Devices publish/subscribe to topics to exchange sensor readings with minimal overhead. |
| **[InfluxDB](https://www.influxdata.com/)** | Time-Series Database | Purpose-built for high-write, time-stamped workloads. Stores every sensor reading, and rolls them up hourly for long-term trends. |
| **[Node-RED](https://nodered.org/)** | Workflow Engine | Low-code, flow-based programming tool for wiring together MQTT topics, HTTP APIs, databases, and custom logic. Build IoT processing pipelines without boilerplate. |
| **[Grafana](https://grafana.com/)** | Data Visualization | Dashboarding platform that connects directly to InfluxDB to render real-time charts, gauges, and alerts. Provides at-a-glance operational visibility into device health. |
| **[Telegraf](https://www.influxdata.com/time-series-platform/telegraf/)** *(optional)* | Metrics Agent | Collects host metrics (CPU, memory, disk, load) and Mosquitto broker stats into the `system_health` bucket, shown on the **Stack Health** dashboard. |
| **[Loki](https://grafana.com/oss/loki/)** + **[Alloy](https://grafana.com/oss/alloy/)** *(optional)* | Logs | Alloy collects the logs of every `p4n4-*` container and Loki stores them, for the **Stack Logs** dashboard and Grafana's Explore. |
| **[MQTTX Web](https://mqttx.app/web)** *(optional)* | MQTT Web Client | Browse topics, subscribe and publish from a browser, over the broker's WebSocket port. |

[Node-RED Dashboard 2](https://dashboard.flowfuse.com/) is available as a Node-RED package rather than a service: see [Node-RED Packages](#node-red-packages).

---

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) (v20.10+)
- [Docker Compose](https://docs.docker.com/compose/) (v2.0+)
- At least **2 GB RAM** available to Docker

---

## Getting Started

1. **Clone the repository**

   ```bash
   git clone https://github.com/raisga/p4n4-iot.git
   cd p4n4-iot
   ```

2. **Configure environment variables**

   ```bash
   cp .env.example .env
   # Edit .env to set passwords and tokens
   ```

3. **Start the stack**

   ```bash
   docker compose up -d
   ```

4. **Verify services are running**

   ```bash
   docker compose ps
   # or
   make status
   ```

5. **Open the dashboards**

   - Grafana: <http://localhost:3000>
   - Node-RED: <http://localhost:1880>
   - InfluxDB: <http://localhost:8086>

---

## Choosing Services

Every service is optional. Each one sits in a [Compose profile](https://docs.docker.com/compose/how-tos/profiles/) of its own name, and `COMPOSE_PROFILES` in `.env` lists the ones that start:

```bash
# Default: the MING stack
COMPOSE_PROFILES=mqtt,influxdb,node-red,grafana

# MING stack plus host and broker metrics, container logs and the MQTT web client
COMPOSE_PROFILES=mqtt,influxdb,node-red,grafana,telegraf,loki,alloy,mqtt-ui

# Just a broker
COMPOSE_PROFILES=mqtt
```

| Profile | Service | Needs |
|---------|---------|-------|
| `mqtt` | Mosquitto | — |
| `influxdb` | InfluxDB | — |
| `node-red` | Node-RED | `mqtt`, `influxdb` |
| `grafana` | Grafana | `influxdb` |
| `telegraf` | Telegraf | — (useful with `influxdb`) |
| `loki` | Loki | — |
| `alloy` | Alloy | `loki` |
| `mqtt-ui` | MQTTX Web | — (useful with `mqtt`) |

Run `docker compose up -d --remove-orphans` after changing it. Compose refuses to start a service whose dependency is left out. Telegraf has no hard dependencies: it retries the broker and buffers writes until InfluxDB is up.

If `.env` has no `COMPOSE_PROFILES` line, plain `docker compose up` starts nothing; the `make` targets fall back to the MING stack.

---

## Project Structure

```
p4n4-iot/
├── docker-compose.yml                  # Service definitions (one profile per service)
├── docker-compose.override.yml.example # Local override template (debugging, storage, Docker metrics)
├── Makefile                            # Convenience commands (make up, make backup, etc.)
├── .env.example                        # Environment template (copy to .env)
├── .gitignore
├── config/
│   ├── mosquitto/
│   │   ├── mosquitto.conf              # MQTT broker configuration
│   │   ├── bridge.sh                   # Writes listeners, logins and bridge from .env
│   │   ├── passwd.example              # Device logins template (make mqtt-user)
│   │   ├── acl.example                 # Topic access per login template
│   │   └── certs/                      # TLS certificates and keys (kept out of git)
│   ├── node-red/
│   │   ├── settings.js                 # Node-RED runtime settings
│   │   ├── entrypoint.sh               # Installs NODE_RED_PACKAGES on start
│   │   └── flows/
│   │       └── flows.json              # MQTT-to-InfluxDB pipeline, System 1 log and subflow
│   ├── telegraf/
│   │   └── telegraf.conf               # Host + broker metrics (profile "telegraf")
│   ├── loki/
│   │   └── loki.yml                    # Log store (profile "loki")
│   ├── alloy/
│   │   └── config.alloy                # Container log collector (profile "alloy")
│   └── grafana/
│       └── provisioning/
│           ├── datasources/
│           │   └── datasources.yml     # InfluxDB (one per bucket) and Loki data sources
│           ├── alerting/
│           │   └── system1.yml         # System 1 drift alerts, sent to n8n
│           └── dashboards/
│               ├── dashboards.yml      # Dashboard provisioning config
│               └── json/
│                   ├── iot-overview.json  # Sample IoT dashboard
│                   ├── stack-health.json  # Host and broker metrics (Telegraf)
│                   ├── stack-logs.json    # Container logs (Loki)
│                   └── system1.json       # System 1 decisions, feedback and drift
├── scripts/
│   ├── init-buckets.sh                 # InfluxDB buckets and the hourly rollup task
│   └── selector.sh                     # Interactive service selector
└── README.md
```

---

## InfluxDB Buckets

The stack provisions five buckets automatically on first run:

| Bucket | Retention | Purpose |
|--------|-----------|---------|
| `raw_telemetry` | 30 days | All inbound sensor readings (primary bucket) |
| `processed_metrics` | 365 days | Hourly rollups of `raw_telemetry` |
| `ai_events` | Infinite | AI annotations, anomaly flags, agent logs |
| `system_health` | 7 days | Stack component health metrics (Telegraf host and broker metrics) |
| `sandbox` | 30 days | Development and testing |

`raw_telemetry` is the default write target for all production MQTT flows. Corresponding Grafana data sources are provisioned for each bucket.

Names and retentions are set in `.env` (`INFLUXDB_BUCKET*` and `INFLUXDB_*_RETENTION`). Node-RED, Telegraf and Grafana follow the names: dashboards and alerts query `v.defaultBucket`, the bucket of the data source they use. Both apply when InfluxDB creates the buckets, on its first start; change the retention of an existing bucket with `influx bucket update`.

**Hourly rollups.** The `p4n4-rollup-hourly` InfluxDB task runs five minutes past every hour. It writes the mean, min, max and count of each numeric field in `raw_telemetry` over the hour before to `processed_metrics`, with the same measurement and tags, as `<field>_mean`, `<field>_min`, `<field>_max` and `<field>_count`, timestamped at the start of the hour. Readings that arrive after their hour has been rolled up (a device catching up on old readings) aren't included. Installs from before the task existed get it, and any missing bucket, with `make influx-init`.

---

## MQTT Topic Convention

Devices publish telemetry to:

```
sensors/{device_id}/{measurement}
```

The payload is a JSON object, for example `{"value": 23.5, "unit": "C"}`. Node-RED writes each reading to the `sensor_data` measurement, tagged with `device` and `sensor` from the topic. Numbers, strings and booleans in the payload become fields; `device` and `model` keys in the payload are ignored, because the topic names the device.

| Payload | Stored as |
|---------|-----------|
| `{"value": 23.5, "unit": "C"}` | fields `value=23.5`, `unit="C"` |
| `23.5`, `true` or `on` (no JSON object) | field `value` |
| `{"accel": {"x": 0.1, "y": 9.8}, "rgb": [1, 2, 3]}` | fields `accel_x`, `accel_y`, `rgb_0`, `rgb_1`, `rgb_2` (nested objects and arrays are flattened) |
| `{"value": 1, "ts": 1760000000}` | the reading's time from `ts`, `timestamp` or `time`: epoch seconds, ms, µs or ns, or an ISO 8601 string |

Without a time in the payload, a reading is stored at the time Node-RED received it. A time before 2000 or more than a day ahead (a device without a clock sending its uptime) is ignored with one warning per device in the debug sidebar. Readings are written in batches, one write per bucket of up to 500 readings or every second, so busy fleets don't send InfluxDB a request per message.

| Topic | Destination |
|-------|-------------|
| `sensors/{device_id}/{measurement}` | `raw_telemetry` bucket, `sensor_data` measurement |
| `inference/{device_id}/result` | `raw_telemetry` bucket, `inference` measurement |
| `sandbox/sensors/{device_id}/{measurement}`, `sandbox/inference/{device_id}/result` | `sandbox` bucket |
| `system1/decisions/{set}`, `system1/feedback/{set}` | `ai_events` bucket, `system1_decision` and `system1_feedback` measurements |

Messages carrying `"_stored_by": "p4n4-api"` are skipped: p4n4-api's `POST /api/v1/telemetry` has already written them to InfluxDB (with the device's own timestamp, in `ts`) and publishes them here only so other flows and live views see them.

Inference results from p4n4-ai's edge inference runner (`ei-runner`) are tagged with `device` from the topic, and `model` from the payload when present. Messages on `sensors/` or `inference/` topics with a different shape, such as `sensors/temperature` or `inference/results`, are dropped with a warning in the Node-RED debug sidebar.

**System 1.** When p4n4-ai runs System 1 (laya, profile `system1`), its callers log every decision on `system1/decisions/{set}`, and confirmations on `system1/feedback/{set}`; the **System 1 Decision Log** tab writes them to `ai_events`, and Grafana's **System 1** dashboard shows answers, abstentions, confidence, latency, agreement with people and drift. Flows call System 1 with the **p4n4-system1** subflow (palette: p4n4 AI): the state in `msg.payload`, the set in `msg.set` or the subflow's `SET`, the answers back in `msg.payload`, and on any failure `msg.error` with a null payload. It needs `SYSTEM1_API_KEY` in `.env`, the same value as the ai stack's (`p4n4 ai system1 enable` copies it).

Grafana also provisions three **System 1 drift alerts** (`provisioning/alerting/system1.yml`), one instance per set and question, evaluated every 15 minutes over the last 7 days against the 28 days before: the abstention rate doubled, an option's share moved by more than 20 points, or latency p95 over 2.5 s (half the callers' timeout). Each needs at least 30 decisions in both periods. They go to the **p4n4 System 1 drift** contact point, n8n's System 1 Drift workflow, which publishes them on `system1/drift/{set}`; `SYSTEM1_ALERT_TOKEN`, the same value as the ai stack's, authenticates them. The dashboard's **Labels** annotations show past events labelled with `p4n4 ai system1 label --write`.

---

## External MQTT Broker

The local broker can pull topics from another MQTT broker, the way
`mosquitto_sub -h <host> -u <user> -P <password> -t <topic>` would, and republish them
locally. Node-RED and the edge runner then see those messages as if devices had published
them here. The bridge is inbound only: nothing is published to the external broker.

Set the `MQTT_REMOTE_*` variables in `.env` and restart the `mqtt` service:

```bash
MQTT_REMOTE_HOST=broker.example.com
MQTT_REMOTE_USER=plant-a
MQTT_REMOTE_PASSWORD='s3cr$t'        # single quotes: Compose reads $ and # literally
MQTT_REMOTE_TOPICS=sensors/#,factory/+/+/celsius
MQTT_REMOTE_TLS=true                 # port defaults to 8883 with TLS, 1883 without
```

```bash
docker compose up -d mqtt
make bridge-status                   # connected / not connected
```

| Variable | Default | Description |
|----------|---------|-------------|
| `MQTT_REMOTE_HOST` | *(empty: disabled)* | External broker hostname or IP |
| `MQTT_REMOTE_PORT` | `8883` with TLS, else `1883` | External broker port |
| `MQTT_REMOTE_USER` / `MQTT_REMOTE_PASSWORD` | *(empty)* | Login on the external broker |
| `MQTT_REMOTE_TOPICS` | `sensors/#` | Comma-separated topic filters to pull in |
| `MQTT_REMOTE_PREFIX` | *(empty)* | Prepended locally, e.g. `remote/` turns `sensors/a/t` into `remote/sensors/a/t` |
| `MQTT_REMOTE_QOS` | `0` | Subscription QoS |
| `MQTT_REMOTE_CLIENT_ID` | `p4n4-bridge-<container id>` | Client ID on the external broker |
| `MQTT_REMOTE_TLS` | `false` | Connect over TLS |
| `MQTT_REMOTE_CA_FILE` | system CA bundle | CA certificate in `config/mosquitto/certs/` (for a private CA) |
| `MQTT_REMOTE_CERT_FILE` / `MQTT_REMOTE_KEY_FILE` | *(empty)* | Client certificate and key in `config/mosquitto/certs/`, for mutual TLS |

At container start, `config/mosquitto/bridge.sh` turns these variables into a Mosquitto
bridge config. Mosquitto can't read environment variables itself, and this way the
password stays in `.env` only. The broker logs the bridge target on start (`docker logs
p4n4-mqtt`), and publishes the connection state (`1`/`0`) locally on
`$SYS/broker/connection/p4n4-remote/state`. A bad login shows up there as `0` and in the
log as `Connection Refused: not authorised`; the bridge keeps retrying with backoff.

Keep `MQTT_REMOTE_PREFIX` empty to feed bridged `sensors/{device_id}/{measurement}`
messages straight into the pipeline above. Set a prefix to keep them apart from local
devices; Node-RED's flows then need a matching subscription.

---

## Node-RED Packages

Node-RED packages listed in `NODE_RED_PACKAGES` (comma-separated, in `.env`) are installed when the container starts, into the same place the editor's **Manage palette** installs to. They're installed again only when the list changes, so only that start needs network access; a failed install is logged and Node-RED starts anyway. To remove a package, use **Manage palette**.

[Node-RED Dashboard 2](https://dashboard.flowfuse.com/), for operator UIs built from flows (gauges, charts, buttons, forms):

```bash
NODE_RED_PACKAGES=@flowfuse/node-red-dashboard@1
```

```bash
docker compose up -d node-red   # then add ui-* nodes; the UI is at http://localhost:1880/dashboard
```

---

## Logs

With the `loki` and `alloy` profiles, Alloy reads the logs of every container whose name starts with `p4n4-` (this stack, the ai stack, extras and the dashboard), labels them with `container`, `service` and `project`, and ships them to Loki. Grafana's **Stack Logs** dashboard shows lines per container and the logs themselves, with a container filter and a search box; **Explore** with the **Loki** data source runs any LogQL query.

| Variable | Default | Description |
|----------|---------|-------------|
| `LOKI_RETENTION` | `168h` | How long logs are kept |
| `LOG_MAX_SIZE` / `LOG_MAX_FILE` | `10m` / `3` | Docker's own log files per container (all services, with or without Loki) |

Alloy reads the Docker socket read-only, but anything that can read it sees every container's configuration, environment variables included. Loki stops accepting logs while its disk is more than 90% full.

---

## Usage

### Using Make Commands

```bash
make help           # Show all available commands

make up             # Start the services in COMPOSE_PROFILES
make down           # Stop all services, in any profile
make restart        # Restart all services
make logs           # Follow logs from all services (SERVICE=x for one)
make ps             # Show service status
make status         # Colorized status table

make start SERVICE=grafana   # Start a single service (with deps)
make start SERVICE=telegraf  # Also works for services not in COMPOSE_PROFILES
make stop SERVICE=mqtt        # Stop a single service (warns about deps)

make test-mqtt      # Publish test messages to MQTT
make test-sandbox   # Publish test data to sandbox bucket
make bridge-status  # External broker bridge: connected or not
make mqtt-user NAME=sensor-001         # Add a device login (prompts for the password)
make mqtt-user-delete NAME=sensor-001  # Remove it
make buckets        # List InfluxDB buckets
make influx-init    # Create missing buckets and the hourly rollup task
make backup         # Back up InfluxDB, Grafana, Node-RED and Mosquitto data
make restore BACKUP=backups/<timestamp>
make clean          # Stop services and remove all data volumes
```

### Testing the Data Pipeline

1. Start the stack: `make up`
2. Open Node-RED at <http://localhost:1880> — the sample flow auto-loads from `config/node-red/flows/flows.json`. Deploying from the editor saves back to that file. On Linux, the `config/node-red/flows/` directory must be writable by the container's user (uid 1000), or deploys fail with `EACCES`.
3. Publish test data:

   ```bash
   make test-mqtt
   ```

4. Open Grafana at <http://localhost:3000> and view the **IoT Overview** dashboard (**Stack Health** and **Stack Logs** show data with the `telegraf`, `loki` and `alloy` profiles)

### Publishing Custom Sensor Data

Use any MQTT client to publish JSON payloads:

```bash
mosquitto_pub -h localhost -t 'sensors/my-sensor/temperature' \
  -m '{"value": 23.5, "unit": "C"}'

# With device logins on (MQTT_PASSWORD set)
mosquitto_pub -h localhost -u sensor-001 -P '<password>' \
  -t 'sensors/sensor-001/temperature' -m 23.5
```

Node-RED routes the message to InfluxDB, where it becomes immediately queryable in Grafana.

---

## Backup and Restore

```bash
make backup                              # writes backups/<timestamp>/
make restore BACKUP=backups/20261016-140747
```

A backup holds InfluxDB's own backup (every bucket, with its users and tokens) and the Grafana, Node-RED and Mosquitto data volumes as `.tar.gz` files. It's taken while the services run, and services that aren't running are skipped. `.env`, the `config/` files and Loki's logs are not included: keep `.env` with the backups, and `config/` in git.

`make restore` asks for confirmation, then replaces the data of each service found in the backup; the services must exist (`make up` first on a new machine). Use the `.env` the backup was taken with, because InfluxDB's tokens come back from the backup and Node-RED, Telegraf and Grafana authenticate with `INFLUXDB_TOKEN`.

---

## Ports and Network

| Service | Port | Variables |
|---------|------|-----------|
| MQTT (Mosquitto) | `1883` (MQTT), `9001` (WebSocket), `8883` (TLS, with `MQTT_TLS_*`) | `MQTT_PORT`, `MQTT_WS_PORT`, `MQTT_TLS_PORT`, `MQTT_BIND` |
| InfluxDB | `8086` | `INFLUXDB_PORT`, `INFLUXDB_BIND` |
| Node-RED | `1880` | `NODE_RED_PORT`, `NODE_RED_BIND` |
| Grafana | `3000` | `GRAFANA_PORT`, `GRAFANA_BIND` |
| MQTTX Web | `8081` | `MQTT_UI_PORT`, `MQTT_UI_BIND` |
| Telegraf, Loki, Alloy | none (internal only) | — |

Each `*_BIND` is the host address a service is published on: `0.0.0.0` (default) for every interface, `127.0.0.1` for this machine only. `make status` shows the ports in use.

The services share the `p4n4-net` Docker network with the other p4n4 stacks, on the `172.20.0.0/16` subnet by default. If that overlaps a VPN or another network, set `P4N4_SUBNET` in `.env`, stop every p4n4 stack, run `docker network rm p4n4-net`, and start again.

---

## Default Credentials

All credentials can be customized in `.env`. Defaults (from `.env.example`):

| Service  | Username | Password        |
|----------|----------|-----------------|
| InfluxDB | `admin`  | `adminpassword` |
| Grafana  | `admin`  | `adminpassword` |
| Node-RED | `admin`  | `adminpassword` |
| MQTT     | —        | none: devices connect anonymously until `MQTT_PASSWORD` is set |

**Note:** Change all passwords and the InfluxDB token before deploying to production.

To show Grafana inside the [p4n4-dashboard](https://github.com/raisga/p4n4-dashboard) web UI, set `GRAFANA_ALLOW_EMBEDDING=true` in `.env` (`p4n4 init` does this when the dashboard layer is enabled). To serve Grafana through the dashboard's own origin (for HTTPS), also set `GRAFANA_SUB_PATH=/grafana/` and the dashboard's `GRAFANA_UPSTREAM=http://p4n4-grafana:3000`. For read-only viewing without a login, see the anonymous-viewer example in `docker-compose.override.yml.example`.

---

## Security Hardening

**MQTT logins.** The broker has two kinds of listener. The stack's own services (Node-RED, Telegraf, the ai stack) connect to `mqtt:1883` on `p4n4-net`; that listener isn't published and is always anonymous, so nothing in the stack needs MQTT credentials. Devices connect to the published ports, which accept anonymous clients until you set a login in `.env`:

```bash
MQTT_USER=admin
MQTT_PASSWORD='a-long-random-password'
```

```bash
docker compose up -d mqtt
make mqtt-user NAME=sensor-001          # one login per device (optional)
docker compose restart mqtt
```

From then on every device, the MQTTX web client included, must log in, as `MQTT_USER` or an account in `config/mosquitto/passwd`. To limit what each account may do, copy `config/mosquitto/acl.example` to `config/mosquitto/acl`: by default it lets each device publish only under its own ID (`sensors/<login>/…`). `MQTT_USER` always keeps access to every topic. The container log shows the result on start (`docker logs p4n4-mqtt`).

Anything on `p4n4-net`, and the Docker host itself, can still use the anonymous internal listener, so only trusted containers should join that network.

**MQTT over TLS.** Put a certificate (with its chain) and key in `config/mosquitto/certs/`, then set `MQTT_TLS_CERT_FILE` and `MQTT_TLS_KEY_FILE` to their file names. The broker then also listens for devices on `MQTT_TLS_PORT` (8883), with the same logins.

**Publishing.** Bind services that only this machine (or a reverse proxy) uses to localhost, for example `INFLUXDB_BIND=127.0.0.1` (see [Ports and Network](#ports-and-network)).

**Node-RED credentials.** Set `NODE_RED_CREDENTIAL_SECRET` once, so the credentials saved in flows (`flows/flows_cred.json`) can be read with `.env` alone, not only with the `node-red-data` volume. Changing it after that makes them unreadable.

---

## Local Overrides

Use `docker-compose.override.yml` for machine-specific settings (TLS, GPU, external volumes) without modifying the base `docker-compose.yml`:

```bash
cp docker-compose.override.yml.example docker-compose.override.yml
# Edit docker-compose.override.yml as needed
docker compose up -d
```

The override file is listed in `.gitignore` and will never be committed.

---

## Resources

- [p4n4 Platform](https://github.com/raisga/p4n4) — umbrella repo and architecture docs
- [p4n4-ai](https://github.com/raisga/p4n4-ai) — GenAI stack (Ollama · Letta · n8n)
- [Eclipse Mosquitto](https://mosquitto.org/) — MQTT broker documentation
- [InfluxDB Documentation](https://docs.influxdata.com/) — Time-series database docs
- [Node-RED Documentation](https://nodered.org/docs/) — Flow-based programming docs
- [Grafana Documentation](https://grafana.com/docs/) — Visualization platform docs

---

## License

This project is licensed under the [MIT License](LICENSE).
