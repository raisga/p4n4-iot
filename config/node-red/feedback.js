"use strict";

const fs = require("node:fs");
const path = require("node:path");

module.exports = function keepFeedback(set, feedback, directory = "/data/system1/feedback") {
    if (typeof set !== "string" || !/^[a-z0-9_-]{1,64}$/.test(set) ||
        !feedback || feedback.set !== set) {
        throw new Error("feedback must name a valid question set");
    }
    const line = Buffer.from(JSON.stringify(feedback) + "\n", "utf8");
    if (line.length > 64 * 1024) {
        throw new Error("feedback example exceeds 64 KiB");
    }
    fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
    const files = fs.readdirSync(directory).filter(name => name.endsWith(".jsonl"));
    const name = set + ".jsonl";
    const filename = path.join(directory, name);
    if (!files.includes(name) && files.length >= 32) {
        throw new Error("feedback storage already contains 32 sets; export and remove old files");
    }
    if (files.includes(name)) {
        const info = fs.lstatSync(filename);
        if (!info.isFile() || info.size + line.length > 1024 * 1024) {
            throw new Error("feedback file is not regular or would exceed 1 MiB; export and remove it");
        }
    }
    fs.appendFileSync(filename, line, { mode: 0o600 });
};
