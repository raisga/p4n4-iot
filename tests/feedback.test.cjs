const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { test } = require("node:test");
const keepFeedback = require("../config/node-red/feedback");

function directory(t) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "p4n4-feedback-"));
    t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
    return dir;
}

test("keeps complete UTF-8 JSON lines for evaluation", t => {
    const dir = directory(t);
    const first = { set: "incident-triage", id: "one", state: { alert: "\u00e9lectrique" } };
    const second = { ...first, id: "two" };
    keepFeedback(first.set, first, dir);
    keepFeedback(second.set, second, dir);
    const rows = fs.readFileSync(path.join(dir, first.set + ".jsonl"), "utf8");
    assert.deepEqual(rows.trimEnd().split("\n").map(JSON.parse), [first, second]);
});

test("rejects unsafe names, mismatched sets and oversized examples before writing", t => {
    const dir = directory(t);
    for (const set of ["../outside", "bad/name", "", "x".repeat(65)]) {
        assert.throws(() => keepFeedback(set, { set }, dir), /valid question set/);
    }
    assert.throws(() => keepFeedback("one", { set: "two" }, dir), /valid question set/);
    assert.throws(
        () => keepFeedback("one", { set: "one", state: "\u00e9".repeat(32 * 1024) }, dir),
        /64 KiB/
    );
    assert.deepEqual(fs.readdirSync(dir), []);
});

test("does not grow a full feedback file or overwrite existing examples", t => {
    const dir = directory(t);
    const filename = path.join(dir, "one.jsonl");
    const contents = Buffer.alloc(1024 * 1024, 32);
    fs.writeFileSync(filename, contents);
    assert.throws(() => keepFeedback("one", { set: "one" }, dir), /1 MiB/);
    assert.deepEqual(fs.readFileSync(filename), contents);
});

test("caps the number of sets while allowing more examples in existing files", t => {
    const dir = directory(t);
    for (let i = 0; i < 32; i++) {
        keepFeedback(`set-${i}`, { set: `set-${i}` }, dir);
    }
    assert.throws(() => keepFeedback("overflow", { set: "overflow" }, dir), /32 sets/);
    keepFeedback("set-0", { set: "set-0", id: "another" }, dir);
    assert.equal(fs.readdirSync(dir).length, 32);
});

test("the flow reports persistence errors instead of claiming success", () => {
    const flows = require("../config/node-red/flows/flows.json");
    const writer = flows.find(node => node.id === "file-system1-feedback");
    const run = new Function("msg", "global", "node", writer.func);
    const errors = [];
    const msg = { payload: JSON.stringify({ set: "one" }) };
    assert.equal(run(msg, { get: () => () => { throw new Error("disk full"); } }, {
        error: text => errors.push(text)
    }), null);
    assert.deepEqual(errors, ["Feedback not kept: disk full"]);
});
