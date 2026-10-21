// menubar-tools: local agent telemetry; never stores prompts or tool arguments.
import { mkdirSync, writeFileSync, renameSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { createHash, randomUUID } from "node:crypto";

export default function (pi) {
  const directory = join(homedir(), "Library/Application Support/MenuBarTools/sessions");
  let context;
  let state = "idle";
  let detail = "Session started";
  let timer;
  let lastError = "";
  let fallbackID = randomUUID();
  let running = false;
  let prompts = 0;

  function publish() {
    if (!context) return;
    try {
      const sessionID = context.sessionManager.getSessionId() || fallbackID;
      const key = createHash("sha256").update(`pi:${sessionID}`).digest("hex");
      mkdirSync(directory, { recursive: true, mode: 0o700 });
      const target = join(directory, `${key}.json`);
      const temporary = join(directory, `.${key}-${randomUUID()}.tmp`);
      writeFileSync(temporary, JSON.stringify({
        schemaVersion: 1, agent: "pi", sessionID,
        project: context.cwd, state, detail,
        updatedAt: Date.now() / 1000, pid: process.pid,
      }), { mode: 0o600 });
      renameSync(temporary, target);
      lastError = "";
    } catch (error) {
      const message = `MenuBarTools telemetry failed: ${String(error)}`;
      if (message !== lastError) {
        context.ui.notify(message, "error");
        lastError = message;
      }
    }
  }

  function update(next, message, ctx) {
    if (ctx) context = ctx;
    state = prompts > 0 && next !== "ended" ? "blocked" : next;
    detail = state === "blocked" && prompts > 0 ? "Waiting for your input" : message;
    publish();
  }

  pi.on("session_start", (_event, ctx) => {
    context = ctx;
    fallbackID = randomUUID();
    running = false;
    prompts = 0;
    update("idle", "Session started");
    clearInterval(timer);
    timer = setInterval(publish, 15_000);
    timer.unref();
  });
  const started = (_event, ctx) => {
    running = true;
    update("working", "Processing", ctx);
  };
  pi.on("before_agent_start", started);
  pi.on("agent_start", started);
  pi.on("tool_execution_start", (_event, ctx) => update("working", "Using a tool", ctx));
  pi.on("tool_execution_end", (_event, ctx) => update("working", "Processing", ctx));
  pi.on("agent_settled", (_event, ctx) => {
    running = false;
    update("idle", "Turn finished", ctx);
  });
  pi.on("ui_prompt_start", (_event, ctx) => {
    prompts += 1;
    update("blocked", "Waiting for your input", ctx);
  });
  pi.on("ui_prompt_end", (_event, ctx) => {
    prompts = Math.max(0, prompts - 1);
    update(running ? "working" : "idle", "Dialog closed", ctx);
  });
  pi.on("session_shutdown", () => {
    clearInterval(timer);
    update("ended", "Session ended");
    context = undefined;
  });
  pi.registerCommand("menubar-status", {
    description: "Set menu bar state: blocked, working, or idle (for custom approval dialogs)",
    handler: async (args, ctx) => {
      const next = args.trim();
      if (!["blocked", "working", "idle"].includes(next)) {
        ctx.ui.notify("Usage: /menubar-status blocked|working|idle", "warning");
        return;
      }
      update(next, next === "blocked" ? "Waiting for your input" : "Manually set", ctx);
    },
  });
}
