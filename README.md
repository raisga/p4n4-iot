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
- [Usage](#usage)
- [Default Ports](#default-ports)
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
| **[InfluxDB](https://www.influxdata.com/)** | Time-Series Database | Purpose-built for high-write, time-stamped workloads. Stores every sensor reading with nanosecond precision so you can query, downsample, and retain data efficiently. |
| **[Node-RED](https://nodered.org/)** | Workflow Engine | Low-code, flow-based programming tool for wiring together MQTT topics, HTTP APIs, databases, and custom logic. Build IoT processing pipelines without boilerplate. |
| **[Grafana](https://grafana.com/)** | Data Visualization | Dashboarding platform that connects directly to InfluxDB to render real-time charts, gauges, and alerts. Provides at-a-glance operational visibility into device health. |
| **[Telegraf](https://www.influxdata.com/time-series-platform/telegraf/)** *(optional)* | Metrics Agent | Collects host metrics (CPU, memory, disk, load) and Mosquitto broker stats into the `system_health` bucket. Off by default. |

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

# MING stack plus host and broker metrics
COMPOSE_PROFILES=mqtt,influxdb,node-red,grafana,telegraf

# Just a broker
COMPOSE_PROFILES=mqtt
```

Run `docker compose up -d --remove-orphans` after changing it. Node-RED needs `mqtt` and `influxdb`, and Grafana needs `influxdb`; Compose refuses to start a service whose dependency is left out. Telegraf has no hard dependencies: it retries the broker and buffers writes until InfluxDB is up.

If `.env` has no `COMPOSE_PROFILES` line, plain `docker compose up` starts nothing; the `make` targets fall back to the MING stack.

---

## Project Structure

```
p4n4-iot/
├── docker-compose.yml                  # MING stack service definitions
├── docker-compose.override.yml.example # Local override template (GPU, ports, dev)
├── Makefile                            # Convenience commands (make up, make down, etc.)
├── .env.example                        # Environment template (copy to .env)
├── .gitignore
├── config/
│   ├── mosquitto/
│   │   ├── mosquitto.conf              # MQTT broker configuration
│   │   ├── passwd.example             # Auth password file template
│   │   └── acl.example                # Topic ACL template
│   ├── node-red/
│   │   ├── settings.js                # Node-RED runtime settings
│   │   └── flows/
│   │       └── flows.json             # MQTT-to-InfluxDB pipeline flows
│   ├── telegraf/
│   │   └── telegraf.conf              # Host + broker metrics (profile "telegraf")
│   └── grafana/
│       └── provisioning/
│           ├── datasources/
│           │   └── datasources.yml    # Auto-configure all InfluxDB datasources
│           └── dashboards/
│               ├── dashboards.yml     # Dashboard provisioning config
│               └── json/
│                   └── iot-overview.json  # Sample IoT dashboard
├── scripts/
│   ├── init-buckets.sh                # InfluxDB bucket initialization
│   └── selector.sh                    # Interactive service selector
└── README.md
```

---

## InfluxDB Buckets

The stack provisions five buckets automatically on first run:

| Bucket | Retention | Purpose |
|--------|-----------|---------|
| `raw_telemetry` | 30 days | All inbound sensor readings (primary bucket) |
| `processed_metrics` | 365 days | Downsampled / aggregated data |
| `ai_events` | Infinite | AI annotations, anomaly flags, agent logs |
| `system_health` | 7 days | Stack component health metrics (Telegraf host and broker metrics) |
| `sandbox` | 30 days | Development and testing |

`raw_telemetry` is the default write target for all production MQTT flows. Corresponding Grafana datasources are provisioned for each bucket.

---

## MQTT Topic Convention

Devices publish telemetry to:

```
sensors/{device_id}/{measurement}
```

The payload is a JSON object, for example `{"value": 23.5, "unit": "C"}`. Node-RED writes each reading to the `sensor_data` measurement, tagged with `device` and `sensor` from the topic. Numbers, strings and booleans in the payload become fields; `device` and `model` keys in the payload are ignored, because the topic names the device.

| Topic | Destination |
|-------|-------------|
| `sensors/{device_id}/{measurement}` | `raw_telemetry` bucket, `sensor_data` measurement |
| `inference/{device_id}/result` | `raw_telemetry` bucket, `inference` measurement |
| `sandbox/sensors/{device_id}/{measurement}`, `sandbox/inference/{device_id}/result` | `sandbox` bucket |

Messages carrying `"_stored_by": "p4n4-api"` are skipped: p4n4-api's `POST /api/v1/telemetry` has already written them to InfluxDB (with the device's own timestamp, in `ts`) and publishes them here only so other flows and live views see them.

Inference results from p4n4-edge are tagged with `device` from the topic, and `model` from the payload when present. Messages on `sensors/` or `inference/` topics with a different shape, such as `sensors/temperature` or `inference/results`, are dropped with a warning in the Node-RED debug sidebar.

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

## Usage

### Using Make Commands

```bash
make help           # Show all available commands

make up             # Start the services in COMPOSE_PROFILES
make down           # Stop all services, in any profile
make restart        # Restart all services
make logs           # Follow logs from all services
make ps             # Show service status
make status         # Colorized status table

make start SERVICE=grafana   # Start a single service (with deps)
make start SERVICE=telegraf  # Also works for services not in COMPOSE_PROFILES
make stop SERVICE=mqtt        # Stop a single service (warns about deps)

make test-mqtt      # Publish test messages to MQTT
make test-sandbox   # Publish test data to sandbox bucket
make bridge-status  # External broker bridge: connected or not
make clean          # Stop services and remove all data volumes
```

### Testing the Data Pipeline

1. Start the stack: `make up`
2. Open Node-RED at <http://localhost:1880> — the sample flow auto-loads from `config/node-red/flows/flows.json`. Deploying from the editor saves back to that file. On Linux, the `config/node-red/flows/` directory must be writable by the container's user (uid 1000), or deploys fail with `EACCES`.
3. Publish test data:

   ```bash
   make test-mqtt
   ```

4. Open Grafana at <http://localhost:3000> and view the **IoT Overview** dashboard

### Publishing Custom Sensor Data

Use any MQTT client to publish JSON payloads:

```bash
mosquitto_pub -h localhost -t 'sensors/my-sensor/temperature' \
  -m '{"value": 23.5, "unit": "C"}'
```

Node-RED routes the message to InfluxDB, where it becomes immediately queryable in Grafana.

---

## Default Ports

| Service          | Port                              |
|------------------|-----------------------------------|
| MQTT (Mosquitto) | `1883` (MQTT), `9001` (WebSocket) |
| InfluxDB         | `8086`                            |
| Node-RED         | `1880`                            |
| Grafana          | `3000`                            |
| Telegraf         | none (outbound only)              |

---

## Default Credentials

All credentials can be customized in `.env`. Defaults (from `.env.example`):

| Service  | Username | Password        |
|----------|----------|-----------------|
| InfluxDB | `admin`  | `adminpassword` |
| Grafana  | `admin`  | `adminpassword` |

To show Grafana inside the [p4n4-dashboard](https://github.com/raisga/p4n4-dashboard) web UI, set `GRAFANA_ALLOW_EMBEDDING=true` in `.env` (`p4n4 init` does this when the dashboard layer is enabled). To serve Grafana through the dashboard's own origin (for HTTPS), also set `GRAFANA_SUB_PATH=/grafana/` and the dashboard's `GRAFANA_UPSTREAM=http://p4n4-grafana:3000`. For read-only viewing without a login, see the anonymous-viewer example in `docker-compose.override.yml.example`.
| Node-RED | `admin`  | `adminpassword` |

**Note:** Change all passwords and the InfluxDB token before deploying to production.

---

## Security Hardening

By default, Mosquitto runs with `allow_anonymous true` for ease of local development. For production:

1. Generate a password file:
   ```bash
   docker run --rm -it eclipse-mosquitto:2 mosquitto_passwd -c /dev/stdout node-red
   # Copy output to config/mosquitto/passwd
   ```

2. Use `config/mosquitto/passwd.example` and `config/mosquitto/acl.example` as starting templates.

3. Enable authentication in `config/mosquitto/mosquitto.conf`:
   ```
   allow_anonymous false
   password_file /mosquitto/config/passwd
   acl_file /mosquitto/config/acl
   ```

4. Mount the files via `docker-compose.override.yml` (see [Local Overrides](#local-overrides)).

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

This project is licensed under the [Apache License 2.0](LICENSE).
