#!/usr/bin/env python3
"""Observe agent hooks without producing hook decisions or retaining prompt content."""

import argparse
import datetime
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time


def support_dir():
    return Path.home() / "Library/Application Support/MenuBarTools"


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temporary = tempfile.mkstemp(prefix=".menubar-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as stream:
            json.dump(value, stream, allow_nan=False)
            stream.write("\n")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def event_time(payload, now):
    value = payload.get("timestamp")
    if isinstance(value, (float, int)) and not isinstance(value, bool):
        result = value / 1000 if value > 100_000_000_000 else value
    elif isinstance(value, str):
        result = datetime.datetime.fromisoformat(
            value.replace("Z", "+00:00")
        ).timestamp()
    else:
        return now
    if not math.isfinite(result) or result > now + 60:
        raise ValueError("Invalid event timestamp")
    return result


def agent_pid(agent):
    """Find an actual CLI ancestor, not its short-lived hook shell."""
    pid = os.getppid()
    for _ in range(10):
        if pid <= 1:
            return None
        result = subprocess.run(
            ["/bin/ps", "-p", str(pid), "-o", "ppid=", "-o", "comm="],
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
        fields = result.stdout.strip().split(maxsplit=1)
        if len(fields) != 2:
            return None
        parent, command = fields
        basename = Path(command).name.lower()
        if (agent in basename or agent in Path(command).parts) and basename not in (
            "bash",
            "zsh",
            "sh",
            "python3",
        ):
            return pid
        pid = int(parent)
    return None


def state_for(agent, event, payload):
    if event in ("sessionStart", "SessionStart"):
        return "idle", "Session started"
    if event in ("sessionEnd", "SessionEnd"):
        return "ended", "Session ended"
    if event in ("Stop", "agentStop"):
        return "idle", "Turn finished"
    if event in ("StopFailure", "errorOccurred"):
        return "unknown", "Agent reported an error"
    if event in ("notification", "Notification"):
        kind = payload.get("notification_type")
        if kind in ("permission_prompt", "elicitation_dialog"):
            return "blocked", "Waiting for your input"
        if agent == "claude" and kind == "idle_prompt":
            return "idle", "Waiting for a prompt"
        return None
    if event in ("PermissionRequest", "Elicitation"):
        return "blocked", "Waiting for your input"
    if event in ("preToolUse", "PreToolUse"):
        tool = payload.get("toolName", payload.get("tool_name", ""))
        if tool in ("ask_user", "AskUserQuestion"):
            return "blocked", "Waiting for your answer"
        return "working", "Using a tool"
    if event in (
        "UserPromptSubmit",
        "userPromptSubmitted",
        "PostToolUse",
        "postToolUse",
        "PostToolUseFailure",
        "postToolUseFailure",
        "ElicitationResult",
    ):
        return "working", "Processing"
    raise ValueError(f"Unsupported {agent} event: {event}")


def parse_usage(payload):
    raw = payload.get("rate_limits")
    if raw is None:
        return None
    if not isinstance(raw, dict):
        raise ValueError("rate_limits must be an object")
    usage = {}
    for source, target in (("five_hour", "fiveHour"), ("seven_day", "sevenDay")):
        window = raw.get(source)
        if window is None:
            continue
        percentage, reset = window["used_percentage"], window["resets_at"]
        if (
            isinstance(percentage, bool)
            or isinstance(reset, bool)
            or not isinstance(percentage, (int, float))
            or not isinstance(reset, (int, float))
            or not math.isfinite(percentage)
            or not math.isfinite(reset)
            or not 0 <= percentage <= 100
            or reset <= 0
        ):
            raise ValueError("Invalid quota window")
        usage[target] = {"usedPercentage": percentage, "resetsAt": reset}
    return usage


def observe(agent, event, payload, root=None):
    if not isinstance(payload, dict):
        raise ValueError("Hook payload must be an object")
    # Subagent tool events must not overwrite the parent session's state.
    if payload.get("agentId") or payload.get("agent_id"):
        return
    session_id = payload.get("session_id", payload.get("sessionId"))
    if not isinstance(session_id, str) or not session_id:
        raise ValueError("Missing session ID")
    now = time.time()
    stamp = event_time(payload, now)
    workspace = payload.get("workspace") or {}
    if not isinstance(workspace, dict):
        raise ValueError("Workspace must be an object")
    project = workspace.get("current_dir") or payload.get("cwd", "")
    if not isinstance(project, str):
        raise ValueError("Project path must be a string")
    root = root or support_dir()
    directory = root / "sessions"
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    key = hashlib.sha256(f"{agent}:{session_id}".encode()).hexdigest()
    path = directory / f"{key}.json"
    lock_path = directory / f".{key}.lock"
    lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    with os.fdopen(lock_fd, "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        previous = json.loads(path.read_text()) if path.exists() else {}
        record = {
            **previous,
            "schemaVersion": 1,
            "agent": agent,
            "sessionID": session_id,
            "project": project or previous.get("project", ""),
        }
        if event == "statusline":
            usage = parse_usage(payload)
            if usage is None:
                record.pop("usage", None)
                record.pop("usageUpdatedAt", None)
            else:
                record["usage"] = usage
                record["usageUpdatedAt"] = now
            record.setdefault("state", "unknown")
            record.setdefault("updatedAt", now)
            record.setdefault("detail", "Waiting for lifecycle events")
        else:
            transition = state_for(agent, event, payload)
            if transition is None or stamp < previous.get("_stateAt", 0):
                return
            record["state"], record["detail"] = transition
            record["updatedAt"] = now
            record["_stateAt"] = stamp
        if event in ("sessionStart", "SessionStart") or not record.get("pid"):
            record["pid"] = agent_pid(agent)
        atomic_json(path, record)


def statusline(payload, raw):
    try:
        observe("claude", "statusline", payload)
    except (
        ValueError,
        TypeError,
        KeyError,
        OSError,
        subprocess.SubprocessError,
    ) as error:
        print(f"MenuBarTools telemetry error: {error}", file=sys.stderr)
    saved = support_dir() / "original-statusline.json"
    original = json.loads(saved.read_text()) if saved.exists() else None
    if original and original.get("command"):
        # This is the user's pre-existing, trusted status-line shell command.
        return subprocess.run(
            original["command"], shell=True, input=raw, check=False
        ).returncode
    model = payload.get("model", {}).get("display_name", "Claude")
    usage = parse_usage(payload) or {}
    parts = [model]
    for key, label in (("fiveHour", "5h"), ("sevenDay", "7d")):
        if key in usage:
            parts.append(f"{label} {usage[key]['usedPercentage']:.0f}%")
    print(" | ".join(parts))
    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("agent", choices=["claude", "copilot"])
    parser.add_argument("event")
    args = parser.parse_args()
    raw = sys.stdin.buffer.read()
    try:
        payload = json.loads(raw)
        if args.event == "statusline":
            return statusline(payload, raw)
        observe(args.agent, args.event, payload)
    except (
        ValueError,
        TypeError,
        KeyError,
        OSError,
        subprocess.SubprocessError,
    ) as error:
        print(f"MenuBarTools telemetry error: {error}", file=sys.stderr)
        # Observation must not deny tools or inject hook decisions, even on failure.
    return 0


if __name__ == "__main__":
    sys.exit(main())
