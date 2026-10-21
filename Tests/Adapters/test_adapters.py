import importlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ADAPTERS = Path(__file__).resolve().parents[2] / "Adapters"
sys.path.insert(0, str(ADAPTERS))
bridge = importlib.import_module("agent_bridge")
installer = importlib.import_module("install_integrations")


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.pid_patch = patch.object(bridge, "agent_pid", return_value=None)
        self.pid_patch.start()
        self.payload = {"session_id": "test/../../session", "cwd": "/test/project"}

    def tearDown(self):
        self.pid_patch.stop()
        self.temp.cleanup()

    def read(self):
        return json.loads(next((self.root / "sessions").glob("*.json")).read_text())

    def send(self, event, payload=None, agent="claude"):
        bridge.observe(agent, event, payload or self.payload, self.root)

    def test_full_lifecycle_and_no_prompt_retention(self):
        self.send("SessionStart")
        self.assertEqual(self.read()["state"], "idle")
        self.send("UserPromptSubmit", {**self.payload, "prompt": "sensitive-content"})
        self.assertEqual(self.read()["state"], "working")
        self.assertNotIn("sensitive-content", json.dumps(self.read()))
        self.send("PermissionRequest")
        self.assertEqual(self.read()["state"], "blocked")
        self.send("PostToolUse")
        self.assertEqual(self.read()["state"], "working")
        self.send("Stop")
        self.assertEqual(self.read()["state"], "idle")
        self.send("SessionEnd")
        self.assertEqual(self.read()["state"], "ended")

    def test_copilot_real_payloads(self):
        payload = {
            "sessionId": "copilot-test",
            "cwd": "/project",
            "timestamp": time.time() * 1000,
        }
        self.send("userPromptSubmitted", payload, "copilot")
        self.assertEqual(self.read()["state"], "working")
        self.send(
            "notification",
            {**payload, "notification_type": "permission_prompt"},
            "copilot",
        )
        self.assertEqual(self.read()["state"], "blocked")
        self.send("agentStop", payload, "copilot")
        self.assertEqual(self.read()["state"], "idle")

    def test_nonblocking_copilot_notification_does_not_change_state(self):
        self.send("userPromptSubmitted", agent="copilot")
        self.send(
            "notification",
            {**self.payload, "notification_type": "agent_idle"},
            "copilot",
        )
        self.assertEqual(self.read()["state"], "working")

    def test_subagent_event_cannot_change_parent(self):
        self.send("UserPromptSubmit")
        self.send("Stop", {**self.payload, "agent_id": "subagent"})
        self.assertEqual(self.read()["state"], "working")

    def test_older_event_does_not_overwrite_newer_state(self):
        now = time.time()
        self.send("UserPromptSubmit", {**self.payload, "timestamp": now})
        self.send("Stop", {**self.payload, "timestamp": now - 10})
        self.assertEqual(self.read()["state"], "working")

    def test_statusline_preserves_state_and_tracks_both_windows(self):
        self.send("PermissionRequest")
        usage = {
            "five_hour": {"used_percentage": 25.5, "resets_at": time.time() + 3600},
            "seven_day": {"used_percentage": 70, "resets_at": time.time() + 86400},
        }
        self.send("statusline", {**self.payload, "rate_limits": usage})
        record = self.read()
        self.assertEqual(record["state"], "blocked")
        self.assertEqual(record["usage"]["fiveHour"]["usedPercentage"], 25.5)
        self.assertEqual(record["usage"]["sevenDay"]["usedPercentage"], 70)
        self.assertIn("usageUpdatedAt", record)
        self.send("statusline")
        self.assertNotIn("usage", self.read())

    def test_invalid_quota_is_rejected(self):
        for percentage in (True, -1, 101, float("nan")):
            with self.assertRaises(ValueError):
                bridge.parse_usage(
                    {
                        "rate_limits": {
                            "five_hour": {
                                "used_percentage": percentage,
                                "resets_at": 2000,
                            }
                        }
                    }
                )

    def test_missing_session_rejected(self):
        with self.assertRaises(ValueError):
            self.send("SessionStart", {"cwd": "/test"})

    def test_resumed_session_replaces_dead_process_id(self):
        with patch.object(bridge, "agent_pid", return_value=100):
            self.send("SessionStart")
        self.send("SessionEnd")
        with patch.object(bridge, "agent_pid", return_value=200):
            self.send("SessionStart")
        self.assertEqual(self.read()["pid"], 200)
        self.assertEqual(self.read()["state"], "idle")

    def test_original_statusline_receives_identical_input(self):
        bridge.atomic_json(self.root / "original-statusline.json", {"command": "cat"})
        raw = json.dumps(self.payload).encode()
        with patch.object(bridge, "support_dir", return_value=self.root):
            with patch.object(bridge.subprocess, "run") as run:
                run.return_value.returncode = 0
                self.assertEqual(bridge.statusline(self.payload, raw), 0)
                self.assertEqual(run.call_args.kwargs["input"], raw)

    def test_telemetry_failure_does_not_break_existing_statusline(self):
        bridge.atomic_json(self.root / "original-statusline.json", {"command": "cat"})
        with patch.object(bridge, "support_dir", return_value=self.root):
            with patch.object(bridge, "observe", side_effect=OSError("disk error")):
                with patch.object(bridge.subprocess, "run") as run:
                    run.return_value.returncode = 0
                    self.assertEqual(bridge.statusline(self.payload, b"original"), 0)
                    self.assertEqual(run.call_args.kwargs["input"], b"original")

    def test_observation_errors_never_deny_tools(self):
        result = subprocess.run(
            [
                sys.executable,
                str(ADAPTERS / "agent_bridge.py"),
                "copilot",
                "preToolUse",
            ],
            input=b"invalid json",
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")
        self.assertIn(b"telemetry error", result.stderr)


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        self.env = patch.dict(os.environ, {"COPILOT_HOME": str(self.home / ".copilot")})
        self.env.start()
        self.settings = self.home / ".claude/settings.json"
        self.original = {
            "theme": "dark",
            "statusLine": {"type": "command", "command": "cat", "padding": 2},
            "hooks": {
                "Stop": [{"hooks": [{"type": "command", "command": "echo existing"}]}]
            },
        }
        bridge.atomic_json(self.settings, self.original)

    def tearDown(self):
        self.env.stop()
        self.temp.cleanup()

    def install(self):
        installer.configure(self.home, ADAPTERS)

    def test_install_is_idempotent_and_uninstall_restores_existing_config(self):
        self.install()
        first = json.loads(self.settings.read_text())
        self.install()
        self.assertEqual(first, json.loads(self.settings.read_text()))
        self.assertEqual(first["hooks"]["Stop"][0], self.original["hooks"]["Stop"][0])
        self.assertEqual(len(first["hooks"]["Stop"]), 2)
        self.assertEqual(first["statusLine"]["padding"], 2)
        self.assertTrue(
            list(self.settings.parent.glob("settings.json.menubar-backup-*"))
        )
        installer.configure(self.home, ADAPTERS, uninstall=True)
        self.assertEqual(self.original, json.loads(self.settings.read_text()))
        self.assertFalse((self.home / ".copilot/hooks/menubar-tools.json").exists())

    def test_user_edits_after_install_are_preserved(self):
        self.install()
        changed = json.loads(self.settings.read_text())
        changed["theme"] = "light"
        changed["statusLine"] = {"type": "command", "command": "echo replacement"}
        bridge.atomic_json(self.settings, changed)
        installer.configure(self.home, ADAPTERS, uninstall=True)
        final = json.loads(self.settings.read_text())
        self.assertEqual(final["theme"], "light")
        self.assertEqual(final["statusLine"]["command"], "echo replacement")

    def test_malformed_settings_are_not_overwritten(self):
        self.settings.write_text("broken")
        with self.assertRaises(ValueError):
            self.install()
        self.assertEqual(self.settings.read_text(), "broken")

    def test_unknown_extension_is_not_overwritten(self):
        extension = self.home / ".pi/agent/extensions/menubar-tools.js"
        extension.parent.mkdir(parents=True)
        extension.write_text("// owned by somebody else")
        with self.assertRaises(ValueError):
            self.install()
        self.assertEqual(json.loads(self.settings.read_text()), self.original)

    def test_fresh_install_uninstall_leaves_no_hooks_or_statusline(self):
        self.settings.unlink()
        self.install()
        installer.configure(self.home, ADAPTERS, uninstall=True)
        self.assertEqual(json.loads(self.settings.read_text()), {})


if __name__ == "__main__":
    unittest.main()
