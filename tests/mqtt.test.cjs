const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const { randomUUID } = require("node:crypto");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { test } = require("node:test");

function docker(args, { input, check = true } = {}) {
    const result = spawnSync("docker", args, {
        encoding: "utf8", input, timeout: 180000, maxBuffer: 8 * 1024 * 1024
    });
    if (result.error) throw result.error;
    if (check) assert.equal(result.status, 0, result.stderr + result.stdout);
    return result;
}

function broker(t, root, credentials, acl) {
    const config = JSON.parse(docker([
        "compose", "--project-directory", root, "--env-file", path.join(root, ".env.example"),
        "--profile", "*", "config", "--format", "json"
    ]).stdout);
    const service = config.services.mqtt;
    assert(service.ports.some(port => port.published === "1883" && port.target === 1884));
    assert(!service.ports.some(port => port.target === 1883), "private listener must not be published");

    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "p4n4-mqtt-"));
    const file = path.join(dir, "compose.json");
    const args = ["compose", "--project-name", "p4n4-mqtt-test-" + randomUUID().slice(0, 8), "-f", file];
    let configured = false;
    t.after(() => {
        try {
            if (configured) docker([...args, "down", "--volumes", "--remove-orphans"]);
        } finally {
            fs.rmSync(dir, { recursive: true, force: true });
        }
    });
    service.volumes = service.volumes.filter(volume => volume.type === "bind").map((volume, i) => {
        const target = path.join(dir, `bind-${i}`);
        fs.mkdirSync(target);
        if (volume.target === "/p4n4") {
            // Copy only public configuration, never a deployment's passwd, ACL or private keys.
            for (const name of ["mosquitto.conf", "bridge.sh", "auth.sh"]) {
                const source = path.join(volume.source, name);
                if (fs.existsSync(source)) {
                    fs.writeFileSync(path.join(target, name), fs.readFileSync(source, "utf8").replace(/\r\n/g, "\n"));
                }
            }
            if (acl) fs.writeFileSync(path.join(target, "acl"), acl);
        } else {
            assert.equal(volume.target, "/mosquitto/certs");
        }
        return { ...volume, source: target };
    });
    for (const key of ["container_name", "ports", "networks", "profiles", "depends_on"]) {
        delete service[key];
    }
    service.restart = "no";
    service.environment = {
        ...service.environment,
        MQTT_USER: "", MQTT_PASSWORD: "", MQTT_READONLY_USER: "", MQTT_READONLY_PASSWORD: "",
        MQTT_REMOTE_HOST: "", MQTT_TLS_CERT_FILE: "", MQTT_TLS_KEY_FILE: "",
        ...credentials
    };
    service.healthcheck = { ...service.healthcheck, interval: "1s", start_period: "0s", retries: 15 };
    fs.writeFileSync(file, JSON.stringify({ services: { mqtt: service } }));
    configured = true;
    return {
        start() {
            const result = docker([...args, "up", "-d", "--wait", "--wait-timeout", "30"], { check: false });
            if (result.status !== 0) {
                const logs = docker([...args, "logs", "--no-color"], { check: false });
                assert.fail(result.stderr + result.stdout + logs.stdout + logs.stderr);
            }
        },
        exec: (command, options) => docker([...args, "exec", "-T", "mqtt", ...command], options),
        run: () => docker([...args, "run", "--rm", "--no-deps", "-T", "mqtt"], { check: false })
    };
}

const authenticated = {
    MQTT_USER: "publisher", MQTT_PASSWORD: "publisher-test-password",
    MQTT_READONLY_USER: "reader", MQTT_READONLY_PASSWORD: "reader-test-password"
};
const roots = [{ name: "core", root: path.resolve(__dirname, "..") }];
if (process.env.P4N4_TEMPLATE_ROOT) {
    for (const name of fs.readdirSync(process.env.P4N4_TEMPLATE_ROOT)) {
        const template = path.join(process.env.P4N4_TEMPLATE_ROOT, name);
        const root = fs.existsSync(path.join(template, "docker-compose.yml"))
            ? template : path.join(template, "iot");
        if (fs.existsSync(path.join(root, "config", "mosquitto", "mosquitto.conf"))) {
            roots.push({ name, root });
        }
    }
}

for (const { name, root } of roots) {
    test(name, async t => {
        await t.test("authenticates devices, enforces read-only ACLs and keeps internal clients working", t => {
            const mqtt = broker(t, root, authenticated);
            mqtt.start();
            const publish = ["mosquitto_pub", "-V", "mqttv5", "-q", "1", "-p", "1884",
                "-t", "sensors/reader/temperature", "-r"];
            const owner = ["-u", authenticated.MQTT_USER, "-P", authenticated.MQTT_PASSWORD];
            const reader = ["-u", authenticated.MQTT_READONLY_USER, "-P", authenticated.MQTT_READONLY_PASSWORD];
            assert.notEqual(mqtt.exec([...publish, "-m", "anonymous"], { check: false }).status, 0);
            assert.notEqual(mqtt.exec([...publish, "-u", "publisher", "-P", "wrong", "-m", "wrong"],
                { check: false }).status, 0);
            mqtt.exec([...publish, ...owner, "-m", "stored"]);
            const subscribe = ["mosquitto_sub", "-p", "1884", "-t", "sensors/reader/temperature", "-C", "1", "-W", "3"];
            assert.equal(mqtt.exec([...subscribe, ...reader]).stdout.trim(), "stored");
            const denied = mqtt.exec([...publish, ...reader, "-m", "forged"], { check: false });
            assert.match(denied.stderr + denied.stdout, /not authori[sz]ed/i);
            assert.equal(mqtt.exec([...subscribe, ...owner]).stdout.trim(), "stored");
            for (const [message, credentials] of [
                ["anonymous-internal", []], ["configured-internal", owner]
            ]) {
                mqtt.exec(["mosquitto_pub", "-p", "1883", "-q", "1", "-r",
                    "-t", "internal/test", "-m", message, ...credentials]);
                assert.equal(mqtt.exec(["mosquitto_sub", "-p", "1884", "-t", "internal/test",
                    "-C", "1", "-W", "3", ...reader]).stdout.trim(), message);
            }
            mqtt.exec([...publish, ...owner, "-s"], { input: "within-packet-limit" });
            assert.equal(mqtt.exec([...subscribe, ...reader]).stdout.trim(), "within-packet-limit");
            mqtt.exec([...publish, ...owner, "-s"], {
                input: Buffer.alloc(4 * 1024 * 1024, 120), check: false
            });
            assert.equal(mqtt.exec([...subscribe, ...reader]).stdout.trim(), "within-packet-limit");
        });
        await t.test("retains anonymous device access when authentication is not configured", t => {
            const mqtt = broker(t, root, {});
            mqtt.start();
            mqtt.exec(["mosquitto_pub", "-p", "1884", "-q", "1", "-t", "demo/test", "-m", "demo"]);
        });
        await t.test("rejects incomplete read-only credentials instead of enabling anonymous access", t => {
            const mqtt = broker(t, root, { ...authenticated, MQTT_READONLY_PASSWORD: "" });
            const result = mqtt.run();
            assert.notEqual(result.status, 0);
            assert.match(result.stderr, /need/);
        });
        await t.test("rejects global write patterns that would bypass the read-only account", t => {
            const mqtt = broker(t, root, authenticated, "pattern write sensors/%u/#\n");
            const result = mqtt.run();
            assert.notEqual(result.status, 0);
            assert.match(result.stderr, /global write patterns/);
        });
    });
}
