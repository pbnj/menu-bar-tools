import Darwin
import Foundation

public enum AgentState: String, Codable, Sendable {
  case working, idle, blocked, unknown, ended

  public var title: String {
    switch self {
    case .working: "Working"
    case .idle: "Idle"
    case .blocked: "Needs input"
    case .unknown: "Unknown"
    case .ended: "Ended"
    }
  }

  public var symbol: String {
    switch self {
    case .working: "gearshape.2"
    case .idle: "pause.circle"
    case .blocked: "exclamationmark.bubble"
    case .unknown: "questionmark.circle"
    case .ended: "stop.circle"
    }
  }
}

public struct UsageWindow: Codable, Sendable {
  public let usedPercentage: Double
  public let resetsAt: Double

  public func isCurrent(at date: Date) -> Bool {
    usedPercentage.isFinite && (0...100).contains(usedPercentage)
      && resetsAt.isFinite && resetsAt > date.timeIntervalSince1970
  }
}

public struct AgentUsage: Codable, Sendable {
  public let fiveHour: UsageWindow?
  public let sevenDay: UsageWindow?
}

public struct AgentSession: Codable, Identifiable, Sendable {
  public let schemaVersion: Int
  public let agent: String
  public let sessionID: String
  public let project: String
  public let state: AgentState
  public let updatedAt: Double
  public let pid: Int32?
  public let detail: String?
  public let usage: AgentUsage?
  public let usageUpdatedAt: Double?
  public var id: String { "\(agent):\(sessionID)" }
  public var updatedDate: Date { Date(timeIntervalSince1970: updatedAt) }

  public func displayedState(at now: Date, processAlive: Bool? = nil) -> AgentState {
    if state == .ended { return .ended }
    if let pid, !(processAlive ?? (kill(pid, 0) == 0 || errno == EPERM)) { return .ended }
    if now.timeIntervalSince(updatedDate) > 300 { return .unknown }
    return state
  }

  public static var directory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(
        "Library/Application Support/MenuBarTools/sessions", isDirectory: true)
  }
}

public struct SessionReadResult: Sendable {
  public let sessions: [AgentSession]
  public let errors: [String]

  public static func read(directory: URL = AgentSession.directory) -> SessionReadResult {
    let manager = FileManager.default
    guard manager.fileExists(atPath: directory.path) else {
      return SessionReadResult(sessions: [], errors: [])
    }
    do {
      let files = try manager.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.isRegularFileKey]
      )
      .filter { $0.pathExtension == "json" }
      var sessions: [AgentSession] = []
      var errors: [String] = []
      for file in files {
        do {
          let data = try Data(contentsOf: file)
          let record = try JSONDecoder().decode(AgentSession.self, from: data)
          guard record.schemaVersion == 1, ["claude", "copilot", "pi"].contains(record.agent),
            !record.sessionID.isEmpty, record.updatedAt.isFinite,
            record.updatedAt <= Date().timeIntervalSince1970 + 60,
            record.pid.map({ $0 > 1 }) ?? true
          else {
            throw ToolError("Unsupported or invalid session record.")
          }
          sessions.append(record)
        } catch {
          errors.append("\(file.lastPathComponent): \(error.localizedDescription)")
        }
      }
      return SessionReadResult(
        sessions: sessions.sorted { $0.updatedAt > $1.updatedAt }, errors: errors)
    } catch {
      return SessionReadResult(sessions: [], errors: [error.localizedDescription])
    }
  }
}
