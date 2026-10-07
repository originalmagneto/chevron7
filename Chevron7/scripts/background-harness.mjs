// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

// Runs WebExtension/dist/background.js against a fake `browser` and checks when
// it repeats a native message. Usage: node scripts/background-harness.mjs
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import vm from "node:vm";
import assert from "node:assert/strict";

const source = readFileSync(
  fileURLToPath(new URL("../WebExtension/dist/background.js", import.meta.url)), "utf8");

function load(nativeReplies) {
  const sent = [];
  let listener;
  const browser = {
    runtime: {
      id: "chevron7",
      onMessage: { addListener: (fn) => { listener = fn; } },
      sendNativeMessage: async (_app, message) => {
        sent.push(message.kind);
        const next = nativeReplies.shift();
        if (next instanceof Error) throw next;
        return next;
      },
    },
  };
  // Retries wait for nothing here.
  vm.runInNewContext(source, { browser, setTimeout: (fn) => fn(), console });
  const ask = (message) => listener(message, { id: "chevron7" });
  return { ask, sent };
}

const results = [];
async function test(name, body) {
  try {
    await body();
    results.push(`ok   ${name}`);
  } catch (error) {
    results.push(`FAIL ${name}: ${error.message}`);
    process.exitCode = 1;
  }
}

await test("status is repeated when the app is unavailable while an update restarts its agent", async () => {
  const { ask, sent } = load([
    { ok: false, error: "Chevron7 nebeží alebo nie je dostupný." },
    { ok: true, ready: true, version: "1.4.0" },
  ]);
  const reply = await ask({ kind: "status" });
  assert.equal(reply.ok, true);
  assert.equal(sent.length, 2);
});

await test("status is repeated when the native handler is ended mid-request", async () => {
  const { ask, sent } = load([new Error("SFErrorDomain error 3"), { ok: true, ready: true }]);
  assert.equal((await ask({ kind: "status" })).ok, true);
  assert.equal(sent.length, 2);
});

await test("status is repeated on an empty reply", async () => {
  const { ask, sent } = load([undefined, { ok: true, ready: true }]);
  assert.equal((await ask({ kind: "status" })).ok, true);
  assert.equal(sent.length, 2);
});

await test("status gives up after four attempts with the app's own error", async () => {
  const unavailable = { ok: false, error: "Chevron7 nebeží alebo nie je dostupný." };
  const { ask, sent } = load([unavailable, unavailable, unavailable, unavailable, { ok: true }]);
  const reply = await ask({ kind: "status" });
  assert.equal(reply.ok, false);
  assert.equal(reply.error, unavailable.error);
  assert.equal(sent.length, 4);
});

for (const kind of ["sign", "sign-begin", "sign-result"]) {
  await test(`${kind} is never repeated`, async () => {
    const { ask, sent } = load([{ ok: false, error: "x" }, { ok: true }]);
    assert.equal((await ask({ kind, request: "{}" })).ok, false);
    assert.equal(sent.length, 1);
  });
}

console.log(results.join("\n"));
