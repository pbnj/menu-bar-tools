import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync, mkdtempSync, readdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

test("Pi lifecycle publishes local state without prompt or argument content", async () => {
  const home = mkdtempSync(join(tmpdir(), "menubar-pi-"));
  const oldHome = process.env.HOME;
  process.env.HOME = home;
  const handlers = new Map();
  const commands = new Map();
  try {
    const source = readFileSync(new URL("../../Adapters/pi-extension.js", import.meta.url), "utf8");
    const { default: extension } = await import(`data:text/javascript;base64,${Buffer.from(source).toString("base64")}`);
    extension({
      on: (event, callback) => handlers.set(event, callback),
      registerCommand: (name, command) => commands.set(name, command),
    });
    const context = {
      cwd: "/example/project", sessionManager: { getSessionId: () => "pi-session" },
      ui: { notify: (message) => { throw new Error(message); } },
    };
    const record = () => {
      const dir = join(home, "Library/Application Support/MenuBarTools/sessions");
      return JSON.parse(readFileSync(join(dir, readdirSync(dir).find((f) => f.endsWith(".json")))));
    };
    handlers.get("session_start")({}, context);
    assert.equal(record().state, "idle");
    handlers.get("before_agent_start")({ prompt: "private-prompt" }, context);
    assert.equal(record().state, "working");
    assert.equal(JSON.stringify(record()).includes("private-prompt"), false);
    handlers.get("ui_prompt_start")({ kind: "confirm" }, context);
    assert.equal(record().state, "blocked");
    handlers.get("tool_execution_end")({}, context);
    assert.equal(record().state, "blocked");
    handlers.get("ui_prompt_end")({ kind: "confirm" }, context);
    assert.equal(record().state, "working");
    await commands.get("menubar-status").handler("blocked", context);
    assert.equal(record().state, "blocked");
    handlers.get("agent_settled")({}, context);
    assert.equal(record().state, "idle");
    handlers.get("ui_prompt_start")({ kind: "input" }, context);
    handlers.get("ui_prompt_end")({ kind: "input" }, context);
    assert.equal(record().state, "idle");
    handlers.get("session_shutdown")();
    assert.equal(record().state, "ended");
  } finally {
    handlers.get("session_shutdown")?.();
    if (oldHome === undefined) delete process.env.HOME;
    else process.env.HOME = oldHome;
    rmSync(home, { recursive: true });
  }
});
