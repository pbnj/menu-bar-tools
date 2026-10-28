# Menu Bar Tools

Two native, local-first macOS utilities built with SwiftUI. Requires macOS 13+,
Swift 6+, Python 3.10+, and `gh` with the `gh attention` extension for GitHub data.
Node is needed only to run the Pi adapter tests; Pi provides its own runtime.
No third-party Swift or Python dependencies, server, or new API credentials.

## Build and install

```sh
./scripts/test.sh
./scripts/install.sh
```

The installer builds release `.app` bundles in `dist/`, ad-hoc signs them, copies
them into `~/Applications`, installs the agent adapters, and opens both apps.
There are no Dock icons: use the tray and terminal icons in the menu bar.
For build-only use `./scripts/build.sh`; open the bundles in `dist/` yourself.
Full Xcode is not needed; Apple's Command Line Tools are sufficient.

These are personal-use, non-App-Store apps. For distribution to other machines,
use a Developer ID signing identity (`SIGNING_IDENTITY`) and notarize the bundles.
Ad-hoc signing is not notarization. Launch-at-login is an opt-in switch in each
app and may require approval in System Settings.

## GitHub Attention

Uses the existing `gh` authentication and calls `gh attention --all --json
--reviews` without a shell. Shows categorized PRs, unique-PR count, browser links,
manual/periodic refresh, optional draft exclusion, org/repo filters, and optional
notifications for new category/PR pairs. The awaiting-review category does not
generate notifications. The first successful fetch establishes a baseline.

Approved PRs are listed first. Each has a merge button (also in its context menu)
that asks for a second click to confirm, then runs `gh pr merge <url>` with the
merge method chosen in Settings (squash by default) and, optionally,
`--delete-branch`. Branch protection still applies: a failed merge shows gh's
error and leaves the PR in place.

Pairs that arrived since the baseline are marked new (accent dot, bold title) and
sorted to the top of their section. A "N new" bar offers an "Only new" filter and
"Mark all seen"; opening a PR, or "Mark as seen" in its context menu, clears its
marker. Seen state persists across launches and resets when the org/repo scope
changes.

Settings are in the gear popover. Refresh defaults to two minutes and is clamped
to at least one minute. The app locates `gh` in `~/.local/bin`, Homebrew locations,
and the inherited PATH; an absolute-path override is available. Errors remain
visible alongside the previous result and its timestamp.

Install the extension separately if needed:

```sh
gh extension install pbnj/gh-attention
gh auth status
```

## Claude Status

The popover lists every running Claude Code session: live `claude` processes are
matched to tmux panes by terminal, and to hook records by PID for their Working /
Idle / Needs input / Unknown state. Clicking a session selects its tmux window and
pane and brings Ghostty forward; if no attached client is viewing that tmux
session, the most recently active client is switched to it. Sessions outside tmux
are listed but not clickable. Polls every two seconds. Optional notifications
fire when a session transitions to Needs input. Sessions with no lifecycle events
for five minutes become Unknown, as do sessions started before the integrations
were installed.

The menu bar icon is green while any session is working, orange while any needs
input, and plain when all are idle; it is dimmed when no session is running.

### Adapter installation

`scripts/install.sh` installs all three integrations. The dashboard also has a
**Set up integrations** button:

- Claude: additive hooks in `~/.claude/settings.json` and a status-line wrapper.
- Copilot: a dedicated `~/.copilot/hooks/menubar-tools.json` (or under
  `$COPILOT_HOME/hooks`). Permission notifications, not the pre-approval
  `permissionRequest` event, identify actual approval prompts.
- Pi 1.4+: `~/.pi/agent/extensions/menubar-tools.js`. Uses agent settlement rather
  than individual run completion to detect idle, and UI prompt start/end events
  to detect approval dialogs.

Restart agents after setup. Existing hooks are retained, the existing Claude
status-line command receives its original JSON and keeps rendering, and settings
backups are saved beside the original files. Setup is idempotent. The wrapper
runs the pre-existing status-line command through a shell, just as Claude does.
Only install trusted status-line scripts.

Pi's blocking extension UI dialogs automatically report Needs input, including
while other tools complete in parallel. Older Pi versions or custom dialogs
outside Pi's UI API can report status using `/menubar-status blocked`, then
`working` or `idle`. Copilot and Claude permission and question-tool events are
detected automatically. Hooks that force continuation may temporarily report
idle until the next lifecycle event.

Sandbox policies can prevent hooks from writing to the support directory.
Grant `~/Library/Application Support/MenuBarTools` write access using your
agent's supported sandbox settings; this project never disables a sandbox or
alters permission decisions. Hook observation failures are printed to stderr,
return success to avoid denying agent tools, and do not emit any hook decisions.

### Claude quotas

Reads the documented Claude status-line `rate_limits.five_hour` and `seven_day`
percentages and reset times. Requires a Claude version supporting these fields
and an eligible Pro/Max account. Missing/expired windows are unavailable, not zero.
Percentages are account snapshots, never added across sessions. The newest
report is shown with its age; it is not an independently polled account usage
API. Usage from Claude web/other clients becomes visible only when Claude Code
reports an updated snapshot. Multiple Claude accounts are not separately modeled.

The menu bar shows a Claude icon followed by both windows as Stats.app-style
stacked `5h` and `7d` meters; `–` marks an unavailable window. **Menu bar usage**
in the gear popover picks bars and percentages, bars, percentages, or icon only.
Session state is shown in the popover and through notifications, not the menu bar.

### Local storage and privacy

Adapters store only session ID, CLI type, project path, PID when known,
state/event time, a generic status detail, and optional quota windows in:

```text
~/Library/Application Support/MenuBarTools/
```

No prompts, tool arguments, transcripts, tokens, or credentials are copied into
telemetry. Per-session JSON files are atomically replaced. Python adapters use
per-session locks and ignore out-of-order state events and subagent events.
Pi heartbeats keep its state current; Claude/Copilot use event-driven updates.
Data stays on disk until manually removed; it is never uploaded by these apps.
The GitHub app's only network activity is through the existing `gh` command.

### Remove integrations

```sh
python3 Adapters/install_integrations.py uninstall
```

This removes only this project's hooks/extension and restores the previous Claude
status line if the wrapper is still active. Other edits are preserved. Restart
agents afterward. Disable launch-at-login, quit the apps, then remove their
bundles from `~/Applications` to uninstall the UI. Support data and backups are
retained, including the helper scripts until no active sessions need them.

## Development

```sh
./scripts/test.sh
./scripts/build.sh
python3 Tests/Adapters/smoke_pi.py # Optional: installed Pi runtime, no model request
dist/GitHubAttention.app/Contents/MacOS/GitHubAttention --smoke-test
dist/ClaudeStatus.app/Contents/MacOS/ClaudeStatus --smoke-test
```

Swift tests cover real attention schema decoding, deduplication, argument
construction, unsafe links, state freshness/process exit, expired quotas,
corrupt records, command failures, and timeouts. Python and Node tests cover
adapter transitions, quota forwarding, privacy, and reversible installation.

Interfaces: [Apple MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra),
[Claude hooks](https://code.claude.com/docs/en/hooks),
[Claude status line](https://code.claude.com/docs/en/statusline),
[Copilot hooks](https://docs.github.com/en/copilot/reference/hooks-reference),
and [Pi extensions](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md).
