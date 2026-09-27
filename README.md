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
- [Project Structure](#project-structure)
- [InfluxDB Buckets](#influxdb-buckets)
- [MQTT Topic Convention](#mqtt-topic-convention)
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
| `system_health` | 7 days | Node-RED and stack component health metrics |
| `sandbox` | 30 days | Development and testing |

`raw_telemetry` is the default write target for all production MQTT flows. Corresponding Grafana datasources are provisioned for each bucket.

---

## MQTT Topic Convention

The recommended topic structure is:

```
{site}/{device_type}/{device_id}/{measurement}
```

Examples:

```
factory/temp_sensor/T001/celsius
factory/humidity_sensor/H001/percent
lab/pressure_sensor/P007/bar
```

The bundled Node-RED flows also support flat topic namespaces for quick testing:

```
sensors/temperature    →  raw_telemetry bucket
inference/results      →  raw_telemetry bucket
sandbox/sensors/#      →  sandbox bucket
```

---

## Usage

### Using Make Commands

```bash
make help           # Show all available commands

make up             # Start the full stack
make down           # Stop all services
make restart        # Restart all services
make logs           # Follow logs from all services
make ps             # Show service status
make status         # Colorized status table

make start SERVICE=grafana   # Start a single service (with deps)
make stop SERVICE=mqtt        # Stop a single service (warns about deps)

make test-mqtt      # Publish test messages to MQTT
make test-sandbox   # Publish test data to sandbox bucket
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
# Flat namespace (quick testing)
mosquitto_pub -h localhost -t 'sensors/temperature' \
  -m '{"value": 23.5, "unit": "C", "device": "my-sensor"}'

# Structured namespace (recommended for production)
mosquitto_pub -h localhost -t 'factory/temp_sensor/T001/celsius' \
  -m '{"value": 23.5, "unit": "C", "device": "T001"}'
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

---

## Default Credentials

All credentials can be customized in `.env`. Defaults (from `.env.example`):

| Service  | Username | Password        |
|----------|----------|-----------------|
| InfluxDB | `admin`  | `adminpassword` |
| Grafana  | `admin`  | `adminpassword` |

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
