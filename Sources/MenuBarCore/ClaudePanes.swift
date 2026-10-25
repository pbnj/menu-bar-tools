import Foundation

public struct TmuxPane: Sendable, Equatable {
  public let tty: String
  public let sessionName: String
  public let windowIndex: String
  public let paneIndex: String
  public let windowName: String
  public let path: String
  public var target: String { "\(sessionName):\(windowIndex).\(paneIndex)" }

  static let format =
    "#{pane_tty}\t#{session_name}\t#{window_index}\t#{pane_index}\t#{window_name}\t#{pane_current_path}"

  public static let listArguments = ["list-panes", "-a", "-F", format]

  public static func parse(_ output: String) -> [TmuxPane] {
    output.split(separator: "\n").compactMap { line in
      let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      guard fields.count == 6, fields[0].hasPrefix("/dev/") else { return nil }
      return TmuxPane(
        tty: String(fields[0].dropFirst("/dev/".count)), sessionName: fields[1],
        windowIndex: fields[2], paneIndex: fields[3], windowName: fields[4], path: fields[5])
    }
  }
}

public struct ClaudeProcess: Sendable, Equatable {
  public let pid: Int32
  public let tty: String

  public static let listArguments = ["-A", "-o", "pid=,tty=,comm="]

  /// Claude Code runs as `claude` or as a versioned binary under `claude/versions/`.
  public static func parse(_ output: String) -> [ClaudeProcess] {
    output.split(separator: "\n").compactMap { line in
      let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
      guard fields.count == 3, let pid = Int32(fields[0]), fields[1] != "??" else { return nil }
      let command = fields[2].trimmingCharacters(in: .whitespaces)
      guard URL(fileURLWithPath: command).lastPathComponent == "claude"
        || command.contains("/claude/versions/")
      else { return nil }
      return ClaudeProcess(pid: pid, tty: String(fields[1]))
    }
  }
}

public struct ClaudePane: Identifiable, Sendable {
  public let pane: TmuxPane?
  public let pid: Int32
  public let session: AgentSession?
  public var id: Int32 { pid }

  public func state(at now: Date) -> AgentState {
    session?.displayedState(at: now, processAlive: true) ?? .unknown
  }

  public var project: String { session?.project ?? pane?.path ?? "" }

  /// Joins live Claude processes to tmux panes by TTY and to hook records by PID.
  /// After `/clear` one process owns several records, so the newest one wins.
  public static func join(
    processes: [ClaudeProcess], panes: [TmuxPane], sessions: [AgentSession]
  ) -> [ClaudePane] {
    let paneByTTY = Dictionary(panes.map { ($0.tty, $0) }, uniquingKeysWith: { first, _ in first })
    var sessionByPID: [Int32: AgentSession] = [:]
    for session in sessions where session.agent == "claude" && session.state != .ended {
      guard let pid = session.pid else { continue }
      if let existing = sessionByPID[pid], existing.updatedAt >= session.updatedAt { continue }
      sessionByPID[pid] = session
    }
    var seenTTYs = Set<String>()
    return processes.sorted { $0.pid < $1.pid }.compactMap { process in
      // Skip helper claude processes sharing a terminal with the interactive one.
      guard seenTTYs.insert(process.tty).inserted || sessionByPID[process.pid] != nil
      else { return nil }
      return ClaudePane(
        pane: paneByTTY[process.tty], pid: process.pid, session: sessionByPID[process.pid])
    }.sorted {
      switch ($0.pane, $1.pane) {
      case let (left?, right?):
        return (left.sessionName, Int(left.windowIndex) ?? 0, Int(left.paneIndex) ?? 0)
          < (right.sessionName, Int(right.windowIndex) ?? 0, Int(right.paneIndex) ?? 0)
      case (.some, nil): return true
      case (nil, .some): return false
      case (nil, nil): return $0.pid < $1.pid
      }
    }
  }
}

public struct TmuxClient: Sendable, Equatable {
  public let tty: String
  public let session: String
  public let activity: Int

  public static let listArguments = [
    "list-clients", "-F", "#{client_tty}\t#{client_session}\t#{client_activity}",
  ]

  public static func parse(_ output: String) -> [TmuxClient] {
    output.split(separator: "\n").compactMap { line in
      let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      guard fields.count == 3 else { return nil }
      return TmuxClient(tty: fields[0], session: fields[1], activity: Int(fields[2]) ?? 0)
    }
  }

  /// tmux commands that show `pane`: select it, and if no client is viewing its
  /// session, move the most recently active client there.
  public static func jumpCommands(to pane: TmuxPane, clients: [TmuxClient]) -> [[String]] {
    var commands = [
      ["select-window", "-t", "\(pane.sessionName):\(pane.windowIndex)"],
      ["select-pane", "-t", pane.target],
    ]
    if !clients.contains(where: { $0.session == pane.sessionName }),
      let client = clients.max(by: { $0.activity < $1.activity })
    {
      commands.append(["switch-client", "-c", client.tty, "-t", pane.target])
    }
    return commands
  }
}
