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
