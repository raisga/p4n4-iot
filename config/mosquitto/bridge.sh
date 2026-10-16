#!/bin/sh
# ==============================================================================
# Mosquitto entrypoint
# ==============================================================================
# (Named bridge.sh, its first job, because the p4n4 CLI checks for that file.)
# Writes the broker's listeners, device logins and external-broker bridge into
# /mosquitto/conf.d from .env, then hands off to the image's own entrypoint.
# mosquitto.conf includes that directory. Everything is regenerated on every
# start, so passwords live only in .env and config/mosquitto/passwd.
#
# Listeners (container ports):
#   1883  p4n4-net only, not published: Node-RED, Telegraf, the ai stack and the
#         other containers on the network. Always anonymous.
#   1884  devices, published on MQTT_PORT (default 1883)
#   9001  devices over WebSocket, published on MQTT_WS_PORT (default 9001)
#   8883  devices over TLS, published on MQTT_TLS_PORT (default 8883); only
#         when MQTT_TLS_CERT_FILE and MQTT_TLS_KEY_FILE are set
#
# Device logins (the device listeners only):
#   MQTT_USER              Account for devices and tools
#   MQTT_PASSWORD          Its password. Set: the device listeners require a
#                          login. Empty: they accept anonymous clients.
#   config/mosquitto/passwd  More accounts (make mqtt-user NAME=<name>); used
#                          only while MQTT_PASSWORD is set
#   config/mosquitto/acl   Topic access per account (optional; see acl.example).
#                          MQTT_USER always has access to every topic.
#   MQTT_TLS_CERT_FILE     Server certificate (chain) for the TLS listener
#   MQTT_TLS_KEY_FILE      Its private key
#
# Bridge to an external broker (inbound only, the equivalent of a long-running
# `mosquitto_sub -h <host> -u <user> -P <password> -t <topic>`):
#   MQTT_REMOTE_HOST       External broker hostname or IP (empty = disabled)
#   MQTT_REMOTE_PORT       Port (default: 8883 with TLS, 1883 without)
#   MQTT_REMOTE_USER       Username (optional)
#   MQTT_REMOTE_PASSWORD   Password (optional)
#   MQTT_REMOTE_TOPICS     Comma-separated topic filters to pull in (default: sensors/#)
#   MQTT_REMOTE_PREFIX     Prepended to each topic locally, e.g. remote/ (default: none)
#   MQTT_REMOTE_QOS        Subscription QoS 0-2 (default: 0)
#   MQTT_REMOTE_CLIENT_ID  Client ID on the external broker (default: p4n4-bridge-<hostname>)
#   MQTT_REMOTE_TLS        true to connect over TLS (default: false)
#   MQTT_REMOTE_CA_FILE    CA bundle (default: the system CA bundle)
#   MQTT_REMOTE_CERT_FILE  Client certificate for mutual TLS (optional)
#   MQTT_REMOTE_KEY_FILE   Client key for mutual TLS (optional)
#
# Certificate and key files may be given by name alone: they are looked up in
# config/mosquitto/certs/.
# ==============================================================================
set -eu

CONFIG_DIR=/p4n4
CONF_DIR=/mosquitto/conf.d
CERTS_DIR=/mosquitto/certs

fail() {
    echo "p4n4 mqtt: $*" >&2
    exit 1
}

# Copies a certificate or key into conf.d, so the broker can still read it
# after it drops root (the host's copy may be owner-only), and prints the copy
cert_copy() {
    case "$1" in
        /*) src="$1" ;;
        *) src="$CERTS_DIR/$1" ;;
    esac
    [ -r "$src" ] || fail "certificate or key not found: $src"
    dest="$CONF_DIR/certs/$2"
    cp "$src" "$dest"
    echo "$dest"
}

no_spaces() {
    for value in "$@"; do
        case "$value" in *" "*) fail "MQTT_* values may not contain spaces: '$value'" ;; esac
    done
}

rm -rf "$CONF_DIR"
mkdir -p "$CONF_DIR/certs"
# Owner-only: these files hold passwords and keys
umask 077

# ------------------------------------------------------------------------------
# Device logins
# ------------------------------------------------------------------------------
user="${MQTT_USER:-}"
password="${MQTT_PASSWORD:-}"
login=false
if [ -n "$password" ]; then
    [ -n "$user" ] || fail "MQTT_PASSWORD is set but MQTT_USER is empty"
    case "$user" in *:*) fail "MQTT_USER may not contain ':'" ;; esac
    no_spaces "$user"
    login=true

    if [ -f "$CONFIG_DIR/passwd" ]; then
        cp "$CONFIG_DIR/passwd" "$CONF_DIR/passwd"
    else
        : >"$CONF_DIR/passwd"
    fi
    # Adds MQTT_USER, or replaces its password if the file already has it
    mosquitto_passwd -b "$CONF_DIR/passwd" "$user" "$password"

    if [ -f "$CONFIG_DIR/acl" ]; then
        {
            cat "$CONFIG_DIR/acl"
            echo ""
            echo "# Added by bridge.sh: MQTT_USER has access to every topic"
            echo "user $user"
            echo "topic readwrite #"
            echo "topic read \$SYS/#"
        } >"$CONF_DIR/acl"
    fi
elif [ -f "$CONFIG_DIR/passwd" ]; then
    echo "p4n4 mqtt: config/mosquitto/passwd is ignored until MQTT_USER and MQTT_PASSWORD are set in .env"
fi

# Login settings for one device listener
device_auth() {
    if [ "$login" = true ]; then
        echo "allow_anonymous false"
        echo "password_file $CONF_DIR/passwd"
        if [ -f "$CONF_DIR/acl" ]; then
            echo "acl_file $CONF_DIR/acl"
        fi
    else
        echo "allow_anonymous true"
    fi
}

# ------------------------------------------------------------------------------
# Listeners
# ------------------------------------------------------------------------------
tls_cert="${MQTT_TLS_CERT_FILE:-}"
tls_key="${MQTT_TLS_KEY_FILE:-}"
if [ -n "$tls_cert" ] || [ -n "$tls_key" ]; then
    [ -n "$tls_cert" ] && [ -n "$tls_key" ] \
        || fail "the TLS listener needs both MQTT_TLS_CERT_FILE and MQTT_TLS_KEY_FILE"
fi

{
    echo "# Generated by bridge.sh at container start. Do not edit."
    echo "per_listener_settings true"
    echo ""
    echo "# p4n4-net only (not published): the stack's own services"
    echo "listener 1883"
    echo "protocol mqtt"
    echo "allow_anonymous true"
    echo ""
    echo "# Devices: published on MQTT_PORT"
    echo "listener 1884"
    echo "protocol mqtt"
    device_auth
    echo ""
    echo "# Devices over WebSocket: published on MQTT_WS_PORT"
    echo "listener 9001"
    echo "protocol websockets"
    device_auth
    if [ -n "$tls_cert" ]; then
        echo ""
        echo "# Devices over TLS: published on MQTT_TLS_PORT"
        echo "listener 8883"
        echo "protocol mqtt"
        certfile=$(cert_copy "$tls_cert" server.crt)
        keyfile=$(cert_copy "$tls_key" server.key)
        echo "certfile $certfile"
        echo "keyfile $keyfile"
        device_auth
    fi
} >"$CONF_DIR/10-listeners.conf"

listeners="mqtt :1884, ws :9001"
[ -n "$tls_cert" ] && listeners="$listeners, mqtts :8883"
if [ "$login" = true ]; then
    accounts=$(grep -c . "$CONF_DIR/passwd")
    acl=no
    [ -f "$CONF_DIR/acl" ] && acl=yes
    echo "p4n4 mqtt: devices ($listeners) need a login: $accounts account(s), ACL: $acl"
else
    echo "p4n4 mqtt: devices ($listeners) connect anonymously (MQTT_PASSWORD is empty)"
fi

# ------------------------------------------------------------------------------
# Bridge to an external broker
# ------------------------------------------------------------------------------
# A separate file loaded after the listeners: every option after a bridge's
# "connection" line belongs to that bridge
host="${MQTT_REMOTE_HOST:-}"
if [ -z "$host" ]; then
    echo "p4n4 mqtt: bridge disabled (MQTT_REMOTE_HOST is empty)"
else
    tls="${MQTT_REMOTE_TLS:-false}"
    case "$tls" in
        true | false) ;;
        *) fail "MQTT_REMOTE_TLS must be true or false (got '$tls')" ;;
    esac

    port="${MQTT_REMOTE_PORT:-}"
    if [ -z "$port" ]; then
        if [ "$tls" = true ]; then port=8883; else port=1883; fi
    fi
    qos="${MQTT_REMOTE_QOS:-0}"
    case "$qos" in
        0 | 1 | 2) ;;
        *) fail "MQTT_REMOTE_QOS must be 0, 1 or 2 (got '$qos')" ;;
    esac

    remote_user="${MQTT_REMOTE_USER:-}"
    remote_password="${MQTT_REMOTE_PASSWORD:-}"
    prefix="${MQTT_REMOTE_PREFIX:-}"
    client_id="${MQTT_REMOTE_CLIENT_ID:-p4n4-bridge-$(hostname)}"
    topics="${MQTT_REMOTE_TOPICS:-sensors/#}"

    # Mosquitto reads a value up to the end of the line and a topic line is
    # split on spaces, so neither may appear where they would change the meaning
    no_spaces "$host" "$port" "$remote_user" "$client_id" "$prefix"
    if [ -n "$remote_password" ] && [ -z "$remote_user" ]; then
        fail "MQTT_REMOTE_PASSWORD is set but MQTT_REMOTE_USER is empty"
    fi

    {
        echo "# Generated by bridge.sh from MQTT_REMOTE_* at container start. Do not edit."
        echo "connection p4n4-remote"
        echo "address $host:$port"
        echo "remote_clientid $client_id"
        # Plain MQTT 3.1.1 (no Mosquitto-only bridge flag) works with any broker
        echo "bridge_protocol_version mqttv311"
        echo "try_private false"
        echo "cleansession true"
        echo "start_type automatic"
        # Publishes 1/0 to $SYS/broker/connection/p4n4-remote/state on the local
        # broker only: the external one is never written to
        echo "notifications true"
        echo "notifications_local_only true"
        echo "notification_topic \$SYS/broker/connection/p4n4-remote/state"
        if [ -n "$remote_user" ]; then
            echo "remote_username $remote_user"
        fi
        if [ -n "$remote_password" ]; then
            printf 'remote_password %s\n' "$remote_password"
        fi

        if [ "$tls" = true ]; then
            if [ -n "${MQTT_REMOTE_CA_FILE:-}" ]; then
                cafile=$(cert_copy "$MQTT_REMOTE_CA_FILE" remote-ca.crt)
                echo "bridge_cafile $cafile"
            else
                echo "bridge_cafile /etc/ssl/certs/ca-certificates.crt"
            fi
            if [ -n "${MQTT_REMOTE_CERT_FILE:-}" ] || [ -n "${MQTT_REMOTE_KEY_FILE:-}" ]; then
                [ -n "${MQTT_REMOTE_CERT_FILE:-}" ] && [ -n "${MQTT_REMOTE_KEY_FILE:-}" ] \
                    || fail "mutual TLS needs both MQTT_REMOTE_CERT_FILE and MQTT_REMOTE_KEY_FILE"
                certfile=$(cert_copy "$MQTT_REMOTE_CERT_FILE" remote-client.crt)
                keyfile=$(cert_copy "$MQTT_REMOTE_KEY_FILE" remote-client.key)
                echo "bridge_certfile $certfile"
                echo "bridge_keyfile $keyfile"
            fi
        fi

        # Inbound only: "in" subscribes on the external broker, never publishes to it
        local_prefix="${prefix:-\"\"}"
        count=0
        set -f
        old_ifs="$IFS"
        IFS=,
        for topic in $topics; do
            topic="$(echo "$topic" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
            [ -n "$topic" ] || continue
            case "$topic" in *" "*) fail "topic filters may not contain spaces: '$topic'" ;; esac
            echo "topic $topic in $qos $local_prefix \"\""
            count=$((count + 1))
        done
        IFS="$old_ifs"
        set +f
        [ "$count" -gt 0 ] || fail "MQTT_REMOTE_TOPICS has no topic filters"
    } >"$CONF_DIR/90-bridge.conf"

    scheme=mqtt
    [ "$tls" = true ] && scheme=mqtts
    echo "p4n4 mqtt: bridge $scheme://$host:$port -> local ${prefix:-(no prefix)} [topics: $topics]"
fi

# Readable by the broker after it drops root, so a config reload (SIGHUP) works
if [ "$(id -u)" = 0 ]; then
    chown -R mosquitto:mosquitto "$CONF_DIR"
fi

exec /docker-entrypoint.sh "$@"
