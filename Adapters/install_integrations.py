#!/usr/bin/env python3
"""Idempotent user-level setup with backups and non-destructive removal."""

import argparse
import copy
import datetime
import json
import os
from pathlib import Path
import shlex
import shutil
import sys

from agent_bridge import atomic_json


CLAUDE_EVENTS = (
    "SessionStart",
    "SessionEnd",
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "PostToolUseFailure",
    "PermissionRequest",
    "Notification",
    "Stop",
    "StopFailure",
    "Elicitation",
    "ElicitationResult",
)
COPILOT_EVENTS = (
    "sessionStart",
    "sessionEnd",
    "userPromptSubmitted",
    "preToolUse",
    "postToolUse",
    "postToolUseFailure",
    "notification",
    "agentStop",
    "errorOccurred",
)
MARKER = "menubar-tools"


def load(path, default):
    if not path.exists():
        return copy.deepcopy(default)
    result = json.loads(path.read_text())
    if not isinstance(result, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return result


def backup(path):
    if path.exists():
        stamp = datetime.datetime.now().strftime("%Y%m%d%H%M%S%f")
        shutil.copy2(path, path.with_name(f"{path.name}.menubar-backup-{stamp}"))


def configure(home, source, uninstall=False):
    root = home / "Library/Application Support/MenuBarTools"
    helper = root / "adapters/agent_bridge.py"
    command = f"{shlex.quote(sys.executable)} {shlex.quote(str(helper))}"
    status_command = f"{command} claude statusline"
    claude_path = home / ".claude/settings.json"
    copilot_home = Path(os.environ.get("COPILOT_HOME", str(home / ".copilot")))
    copilot_path = copilot_home / "hooks/menubar-tools.json"
    pi_path = home / ".pi/agent/extensions/menubar-tools.js"
    claude = load(claude_path, {})
    original = copy.deepcopy(claude)
    if claude.get("statusLine") is not None and not isinstance(
        claude["statusLine"], dict
    ):
        raise ValueError("Claude statusLine must be an object.")
    hooks = claude.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise ValueError(
            "Claude hooks must be an object; no configuration was changed."
        )
    # Validate everything before modifying any existing configuration.
    for event in CLAUDE_EVENTS:
        if not isinstance(hooks.get(event, []), list):
            raise ValueError(f"Claude {event} hooks must be an array.")
    if pi_path.exists():
        lines = pi_path.read_text().splitlines()
        if not lines or MARKER not in lines[0]:
            raise ValueError(
                f"Refusing to overwrite an unrecognized extension: {pi_path}"
            )
    if copilot_path.exists() and load(copilot_path, {}).get("_menubarTools") != 1:
        raise ValueError(
            f"Refusing to overwrite an unrecognized hook file: {copilot_path}"
        )

    saved = root / "original-statusline.json"

    # A stable marker in the command also recognizes a previous Python interpreter path.
    def owned(entry):
        return any(
            str(helper) in hook.get("command", "") for hook in entry.get("hooks", [])
        )

    for event in CLAUDE_EVENTS:
        entries = [entry for entry in hooks.get(event, []) if not owned(entry)]
        if not uninstall:
            entries.append(
                {
                    "hooks": [
                        {
                            "type": "command",
                            "command": f"{command} claude {event}",
                            "timeout": 5,
                        }
                    ]
                }
            )
        if entries:
            hooks[event] = entries
        else:
            hooks.pop(event, None)
    if not hooks:
        claude.pop("hooks", None)

    if uninstall:
        current = (claude.get("statusLine") or {}).get("command", "")
        if str(helper) in current:
            previous = json.loads(saved.read_text()) if saved.exists() else None
            if previous is None:
                claude.pop("statusLine", None)
            else:
                claude["statusLine"] = previous
        if claude != original:
            backup(claude_path)
            atomic_json(claude_path, claude)
        for path in (copilot_path, pi_path):
            if path.exists():
                backup(path)
                path.unlink()
        return "Integrations removed. Existing hooks/status line preserved. Restart your agents."

    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    current = claude.get("statusLine")
    current_command = current.get("command", "") if isinstance(current, dict) else ""
    if not saved.exists() or (
        current is not None and str(helper) not in current_command
    ):
        atomic_json(saved, current)
    # Copy first: hook configuration must never point at a missing helper.
    (root / "adapters").mkdir(exist_ok=True, mode=0o700)
    for name in ("agent_bridge.py", "install_integrations.py", "pi-extension.js"):
        destination = root / "adapters" / name
        if (source / name).resolve() != destination.resolve():
            shutil.copy2(source / name, destination)
    claude["statusLine"] = {
        **(current if isinstance(current, dict) else {}),
        "type": "command",
        "command": status_command,
    }
    if claude != original:
        backup(claude_path)
        atomic_json(claude_path, claude)
    copilot = {
        "version": 1,
        "_menubarTools": 1,
        "hooks": {
            event: [
                {
                    "type": "command",
                    "bash": f"{command} copilot {event}",
                    "timeoutSec": 5,
                }
            ]
            for event in COPILOT_EVENTS
        },
    }
    if load(copilot_path, {}) != copilot:
        backup(copilot_path)
        atomic_json(copilot_path, copilot)
    pi_path.parent.mkdir(parents=True, exist_ok=True)
    if (
        pi_path.exists()
        and pi_path.read_bytes() != (source / "pi-extension.js").read_bytes()
    ):
        backup(pi_path)
    shutil.copy2(source / "pi-extension.js", pi_path)
    return (
        "Installed Claude, Copilot and Pi integrations. Restart your agents.\n"
        "Existing Claude status line is chained; configuration backups sit beside the originals.\n"
        "Pi 1.4+ approval dialogs are tracked automatically.\n"
        "Sandboxed Copilot sessions must grant the MenuBarTools support directory write access."
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["install", "uninstall"])
    parser.add_argument(
        "--home", type=Path, default=Path.home(), help="Alternate home for testing"
    )
    args = parser.parse_args()
    try:
        print(
            configure(
                args.home, Path(__file__).resolve().parent, args.action == "uninstall"
            )
        )
    except (OSError, ValueError, TypeError, KeyError) as error:
        print(f"MenuBarTools setup failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
