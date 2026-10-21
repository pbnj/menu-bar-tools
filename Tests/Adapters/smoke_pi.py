"""Exercise the installed Pi runtime without a model request or user configuration."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time


def main():
    executable = shutil.which("pi")
    if not executable:
        raise RuntimeError(
            "Install Pi before running this optional integration smoke check."
        )
    adapter = Path(__file__).resolve().parents[2] / "Adapters/pi-extension.js"
    with tempfile.TemporaryDirectory(prefix="menubar-pi-smoke-") as temporary:
        home = Path(temporary)
        env = {
            **os.environ,
            "HOME": temporary,
            "PI_CODING_AGENT_DIR": str(home / "config"),
            "PI_OFFLINE": "1",
            "PI_TELEMETRY": "0",
        }
        with tempfile.TemporaryFile() as output:
            process = subprocess.Popen(
                [
                    executable,
                    "--mode",
                    "rpc",
                    "--no-session",
                    "--no-extensions",
                    "--no-mcp",
                    "--extension",
                    str(adapter),
                ],
                env=env,
                cwd=temporary,
                stdin=subprocess.PIPE,
                stdout=output,
                stderr=output,
            )
            try:
                directory = home / "Library/Application Support/MenuBarTools/sessions"

                def wait_for(state):
                    deadline = time.monotonic() + 20
                    while time.monotonic() < deadline:
                        if process.poll() is not None:
                            break
                        for path in directory.glob("*.json"):
                            record = json.loads(path.read_text())
                            if record["state"] == state:
                                return
                        time.sleep(0.1)
                    output.seek(0)
                    raise AssertionError(
                        f"Pi did not report {state}: {output.read().decode()[-4000:]}"
                    )

                wait_for("idle")
                for state in ("blocked", "working", "idle"):
                    process.stdin.write(
                        json.dumps(
                            {
                                "type": "prompt",
                                "message": f"/menubar-status {state}",
                            }
                        ).encode()
                        + b"\n"
                    )
                    process.stdin.flush()
                    wait_for(state)
                print(
                    "Pi runtime smoke check passed: extension loaded, states observed, no model request."
                )
            finally:
                process.stdin.close()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()


if __name__ == "__main__":
    main()
