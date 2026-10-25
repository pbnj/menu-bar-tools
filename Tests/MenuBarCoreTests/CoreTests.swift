import Foundation
import Testing

@testable import MenuBarCore

@Test func attentionDecodesRealSchemaAndCountsUniquePRs() throws {
  let data = Data(
    """
    {"approved":[],"failing":[{"number":42,"title":"Fix build","repo":"test/repo",
    "url":"https://github.com/test/repo/pull/42","failingChecks":["test"]}],
    "feedback":[],"review":[{"number":42,"title":"Fix build","repo":"test/repo",
    "url":"https://github.com/test/repo/pull/42"}],"requested":[]}
    """.utf8)
  let snapshot = try AttentionSnapshot(data: data)
  #expect(snapshot.count == 1)
  #expect(snapshot[.failing].first?.browserURL?.scheme == "https")
  #expect(snapshot.notificationKeys == ["failing:https://github.com/test/repo/pull/42"])
}

@Test func seenAttentionStartsCaughtUpAndForgetsDepartedItems() throws {
  func snapshot(_ numbers: [Int]) throws -> AttentionSnapshot {
    let prs = numbers.map {
      #"{"number":\#($0),"title":"t","repo":"o/r","url":"https://github.com/o/r/pull/\#($0)"}"#
    }.joined(separator: ",")
    return try AttentionSnapshot(
      data: Data(#"{"approved":[],"feedback":[],"failing":[\#(prs)],"review":[\#(prs)]}"#.utf8))
  }
  let key = { (n: Int) in "failing:https://github.com/o/r/pull/\(n)" }
  let first = try snapshot([1, 2])
  // No prior state: nothing is new, and awaiting-review items never are.
  #expect(first.reconcileSeen(nil) == [key(1), key(2)])
  // #2 left, #3 arrived: #3 is unseen, #2 is forgotten so a return is new again.
  let seen = try snapshot([1, 3]).reconcileSeen([key(1), key(2)])
  #expect(seen == [key(1)])
  #expect(try snapshot([1, 3]).notificationKeys.subtracting(seen) == [key(3)])
}

@Test func incompleteAttentionOutputIsNotSuccess() {
  #expect(throws: (any Error).self) {
    try AttentionSnapshot(data: Data("{}".utf8))
  }
}

@Test func argumentsAreSeparateAndAlwaysGlobal() {
  let options = AttentionOptions(
    organizations: " one, two ", repositories: "owner/repo, owner/other",
    includeReviews: true, noDrafts: true)
  #expect(
    options.arguments == [
      "attention", "--all", "--json", "--reviews", "--no-drafts",
      "--org", "one", "--org", "two", "--repo", "owner/repo", "--repo", "owner/other",
    ])
}

@Test func unsafeBrowserSchemesAreRejected() throws {
  let pr = try JSONDecoder().decode(
    AttentionPR.self,
    from: Data(
      """
      {"number":1,"title":"No","repo":"a/b","url":"file:///etc/passwd"}
      """.utf8))
  #expect(pr.browserURL == nil)
}

private func session(state: String = "working", updated: Double = 1000) throws -> AgentSession {
  try JSONDecoder().decode(
    AgentSession.self,
    from: Data(
      """
      {"schemaVersion":1,"agent":"claude","sessionID":"test","project":"/test",
      "state":"\(state)","updatedAt":\(updated),"pid":12345}
      """.utf8))
}

@Test func stateDistinguishesStaleDeadAndIdle() throws {
  let current = Date(timeIntervalSince1970: 1100)
  #expect(try session().displayedState(at: current, processAlive: true) == .working)
  #expect(try session().displayedState(at: current, processAlive: false) == .ended)
  #expect(
    try session().displayedState(at: Date(timeIntervalSince1970: 1400), processAlive: true)
      == .unknown)
  #expect(try session(state: "idle").displayedState(at: current, processAlive: true) == .idle)
}

@Test func expiredQuotaIsUnavailableNotZero() throws {
  let quota = try JSONDecoder().decode(
    UsageWindow.self,
    from: Data(#"{"usedPercentage":62,"resetsAt":1200}"#.utf8))
  #expect(quota.isCurrent(at: Date(timeIntervalSince1970: 1100)))
  #expect(!quota.isCurrent(at: Date(timeIntervalSince1970: 1200)))
}

@Test func sessionReadSurfacesCorruptAndUnknownSchemaFiles() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  try Data("broken".utf8).write(to: directory.appendingPathComponent("broken.json"))
  try Data(
    """
    {"schemaVersion":99,"agent":"pi","sessionID":"id","project":"","state":"idle","updatedAt":1000}
    """.utf8
  ).write(to: directory.appendingPathComponent("future.json"))
  let result = SessionReadResult.read(directory: directory)
  #expect(result.sessions.isEmpty)
  #expect(result.errors.count == 2)
}

@Test func runnerCapturesOutputAndReportsFailure() async throws {
  let output = try await ProcessRunner.run(
    URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["hello"])
  #expect(String(decoding: output, as: UTF8.self) == "hello")
  await #expect(throws: (any Error).self) {
    try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/false"), arguments: [])
  }
}

@Test func runnerTimesOut() async {
  await #expect(throws: (any Error).self) {
    try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: 0.1)
  }
}

private func claudeSession(id: String, pid: Int32, state: String, updated: Double) throws
  -> AgentSession
{
  try JSONDecoder().decode(
    AgentSession.self,
    from: Data(
      """
      {"schemaVersion":1,"agent":"claude","sessionID":"\(id)","project":"/repo/\(id)",
      "state":"\(state)","updatedAt":\(updated),"pid":\(pid)}
      """.utf8))
}

@Test func claudeProcessesNeedATerminalAndAClaudeBinary() {
  let processes = ClaudeProcess.parse(
    """
     5596 ttys008  claude
    46755 ttys007  /Users/me/.local/share/claude/versions/2.1.303
    46796 ttys007  npm exec server --config /Users/me/.claude/plugins/config.toml
    54309 ??       claude bg-pty-host
    88226 ??       /Applications/ClaudeStatus.app/Contents/MacOS/ClaudeStatus
    """)
  #expect(
    processes == [
      ClaudeProcess(pid: 5596, tty: "ttys008"), ClaudeProcess(pid: 46755, tty: "ttys007"),
    ])
}

@Test func claudePanesJoinByTTYAndNewestRecord() throws {
  let panes = TmuxPane.parse("/dev/ttys008\twork\t1\t0\tclaude\t/repo/b\n")
  #expect(panes.first?.target == "work:1.0")
  let joined = ClaudePane.join(
    processes: [ClaudeProcess(pid: 7, tty: "ttys007"), ClaudeProcess(pid: 5, tty: "ttys008")],
    panes: panes,
    sessions: [
      try claudeSession(id: "old", pid: 5, state: "idle", updated: 900),
      try claudeSession(id: "new", pid: 5, state: "blocked", updated: 1000),
    ])
  #expect(joined.map(\.pid) == [5, 7])
  #expect(joined[0].session?.sessionID == "new")
  #expect(joined[0].state(at: Date(timeIntervalSince1970: 1010)) == .blocked)
  #expect(joined[1].pane == nil)
  #expect(joined[1].state(at: Date(timeIntervalSince1970: 1010)) == .unknown)
}

@Test func jumpSwitchesAClientOnlyWhenNoneViewsTheSession() {
  let pane = TmuxPane(
    tty: "ttys008", sessionName: "work", windowIndex: "2", paneIndex: "1", windowName: "x",
    path: "/")
  let viewing = [TmuxClient(tty: "/dev/ttys001", session: "work", activity: 1)]
  #expect(TmuxClient.jumpCommands(to: pane, clients: viewing).count == 2)
  let elsewhere = TmuxClient.parse("/dev/ttys001\tother\t5\n/dev/ttys002\tmisc\t9\n")
  #expect(
    TmuxClient.jumpCommands(to: pane, clients: elsewhere).last
      == ["switch-client", "-c", "/dev/ttys002", "-t", "work:2.1"])
}
