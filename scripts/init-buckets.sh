#!/usr/bin/env bash
# ==============================================================================
# InfluxDB Bucket and Task Initialization
# ==============================================================================
# Creates the p4n4 IoT buckets and the hourly rollup task. Runs once, on
# InfluxDB's first start (docker-entrypoint-initdb.d), and again whenever
# `make influx-init` runs it; it only creates what's missing.
#
# Buckets created:
#   raw_telemetry     - all inbound sensor readings          (INFLUXDB_RAW_RETENTION, 30d)
#   processed_metrics - hourly rollups of raw_telemetry      (INFLUXDB_PROCESSED_RETENTION, 365d)
#   ai_events         - AI annotations, anomaly flags        (INFLUXDB_AI_EVENTS_RETENTION, infinite)
#   system_health     - stack component metrics (Telegraf)   (INFLUXDB_HEALTH_RETENTION, 7d)
#   sandbox           - development / testing                (INFLUXDB_SANDBOX_RETENTION, 30d)
#
# Note: raw_telemetry is the DOCKER_INFLUXDB_INIT_BUCKET and is created
# automatically by InfluxDB on first run. This script creates the rest.
# Retention applies when a bucket is created; change an existing one with
# `influx bucket update`.
#
# Task created:
#   p4n4-rollup-hourly - every hour, the mean, min, max and count of each
#   numeric field in raw_telemetry over the hour before, written to
#   processed_metrics with the same measurement and tags, as <field>_mean,
#   <field>_min, <field>_max and <field>_count, at the start of the hour.
#   Readings that arrive after their hour was rolled up (device backfill) are
#   not included.
# ==============================================================================

set -e

ORG="${DOCKER_INFLUXDB_INIT_ORG:-ming}"
TOKEN="${DOCKER_INFLUXDB_INIT_ADMIN_TOKEN:-p4n4-stack-token}"
# During first-run setup, the entrypoint runs a temporary influxd and
# exports INFLUX_HOST for it. Nothing listens on 8086 yet.
HOST="${INFLUX_HOST:-http://localhost:8086}"

BUCKET_RAW="${DOCKER_INFLUXDB_INIT_BUCKET:-raw_telemetry}"
BUCKET_PROCESSED="${INFLUXDB_BUCKET_PROCESSED:-processed_metrics}"
BUCKET_AI_EVENTS="${INFLUXDB_BUCKET_AI_EVENTS:-ai_events}"
BUCKET_HEALTH="${INFLUXDB_BUCKET_HEALTH:-system_health}"
SANDBOX_BUCKET="${INFLUXDB_SANDBOX_BUCKET:-sandbox}"

RETENTION_PROCESSED="${INFLUXDB_PROCESSED_RETENTION:-365d}"
RETENTION_AI_EVENTS="${INFLUXDB_AI_EVENTS_RETENTION:-0}"
RETENTION_HEALTH="${INFLUXDB_HEALTH_RETENTION:-7d}"
RETENTION_SANDBOX="${INFLUXDB_SANDBOX_RETENTION:-30d}"

ROLLUP_TASK="p4n4-rollup-hourly"

CONN=(--host "$HOST" --token "$TOKEN" --org "$ORG")

# No wait loop: the entrypoint waits for the server before running this script.

# ------------------------------------------------------------------------------
# Helper: create bucket if it does not already exist
# ------------------------------------------------------------------------------
create_bucket() {
    local name="$1"
    local retention="$2"   # e.g. "30d", "365d", "7d", or "0" for infinite

    if influx bucket list "${CONN[@]}" --hide-headers 2>/dev/null \
        | awk '{print $2}' | grep -qx "$name"; then
        echo "[init-buckets] Bucket '$name' already exists — skipping."
        return 0
    fi

    local args=(--name "$name" "${CONN[@]}")
    [ -n "$retention" ] && args+=(--retention "$retention")

    if influx bucket create "${args[@]}"; then
        echo "[init-buckets] Bucket '$name' created (retention: ${retention:-infinite})."
    else
        echo "[init-buckets] ERROR: Failed to create bucket '$name'."
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# Helper: create the hourly rollup task if it does not already exist
# ------------------------------------------------------------------------------
create_rollup_task() {
    if influx task list "${CONN[@]}" --hide-headers 2>/dev/null \
        | awk '{print $2}' | grep -qx "$ROLLUP_TASK"; then
        echo "[init-buckets] Task '$ROLLUP_TASK' already exists — skipping."
        return 0
    fi

    local flux
    flux=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '$flux'" RETURN
    cat >"$flux" <<FLUX
import "types"

option task = {name: "$ROLLUP_TASK", every: 1h, offset: 5m}

// The hour before this run: the offset leaves late readings 5 minutes to arrive
data = from(bucket: "$BUCKET_RAW")
    |> range(start: -task.every)
    |> filter(fn: (r) => types.isNumeric(v: r._value))

rollup = (fn, suffix) => data
    |> aggregateWindow(every: task.every, fn: fn, createEmpty: false, timeSrc: "_start")
    |> map(fn: (r) => ({r with _field: r._field + suffix}))

union(tables: [
    rollup(fn: mean, suffix: "_mean"),
    rollup(fn: min, suffix: "_min"),
    rollup(fn: max, suffix: "_max"),
    rollup(fn: count, suffix: "_count"),
])
    |> to(bucket: "$BUCKET_PROCESSED")
FLUX

    if influx task create "${CONN[@]}" --file "$flux" >/dev/null; then
        echo "[init-buckets] Task '$ROLLUP_TASK' created ($BUCKET_RAW → $BUCKET_PROCESSED, hourly)."
    else
        echo "[init-buckets] ERROR: Failed to create task '$ROLLUP_TASK'."
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# Create buckets and tasks
# ------------------------------------------------------------------------------
echo "[init-buckets] Creating p4n4 IoT buckets..."

create_bucket "$BUCKET_PROCESSED"  "$RETENTION_PROCESSED"
create_bucket "$BUCKET_AI_EVENTS"  "$RETENTION_AI_EVENTS"
create_bucket "$BUCKET_HEALTH"     "$RETENTION_HEALTH"
create_bucket "$SANDBOX_BUCKET"    "$RETENTION_SANDBOX"

create_rollup_task

echo "[init-buckets] All buckets and tasks initialized."
