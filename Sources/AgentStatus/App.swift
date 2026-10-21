import AppKit
import MenuBarCore
import MenuBarUI
import SwiftUI

@MainActor
final class AgentModel: ObservableObject {
  @Published var sessions: [AgentSession] = []
  @Published var errors: [String] = []
  @Published var setupMessage: String?
  @Published var installing = false
  @Published var now = Date()
  private var previousStates: [String: AgentState] = [:]
  private var loaded = false

  init() {
    Task {
      while !Task.isCancelled {
        await refresh()
        do { try await Task.sleep(for: .seconds(2)) } catch { break }
      }
    }
  }

  var active: [AgentSession] {
    sessions.filter { $0.displayedState(at: now) != .ended }
  }
  var blocked: Int { active.filter { $0.displayedState(at: now) == .blocked }.count }
  var working: Int { active.filter { $0.displayedState(at: now) == .working }.count }
  var symbol: String {
    if !errors.isEmpty { return "exclamationmark.triangle" }
    if blocked > 0 { return "exclamationmark.bubble" }
    if working > 0 { return "gearshape.2" }
    return "terminal"
  }
  var label: String {
    if blocked > 0 { return "\(blocked) waiting" }
    if working > 0 { return "\(working) working" }
    if active.isEmpty { return "" }
    let allIdle = active.allSatisfy { $0.displayedState(at: now) == .idle }
    return allIdle ? "\(active.count) idle" : "\(active.count) sessions"
  }
  var latestClaudeUsage: AgentSession? {
    sessions.filter { $0.agent == "claude" && $0.usage != nil && $0.usageUpdatedAt != nil }
      .max { ($0.usageUpdatedAt ?? 0) < ($1.usageUpdatedAt ?? 0) }
  }

  func refresh() async {
    let result = await Task.detached(priority: .utility) { SessionReadResult.read() }.value
    now = Date()
    sessions = result.sessions
    errors = result.errors
    var states: [String: AgentState] = [:]
    for session in sessions {
      let state = session.displayedState(at: now)
      states[session.id] = state
      if loaded && state == .blocked && previousStates[session.id] != .blocked
        && UserDefaults.standard.bool(forKey: "notifyBlocked")
      {
        do {
          try await Notifications.shared.send(
            title: "\(session.agent.capitalized) needs input",
            body: URL(fileURLWithPath: session.project).lastPathComponent,
            identifier: session.id)
        } catch { errors.append("Notification failed: \(error.localizedDescription)") }
      }
    }
    previousStates = states
    loaded = true
  }

  func install() async {
    guard !installing else { return }
    installing = true
    defer { installing = false }
    do {
      guard let resources = Bundle.main.resourceURL,
        FileManager.default.fileExists(
          atPath: resources.appendingPathComponent("Adapters/install_integrations.py").path)
      else {
        throw ToolError(
          "Build the .app bundle first using scripts/build.sh; adapters are bundled there.")
      }
      let python = try ProcessRunner.executable("python3")
      let data = try await ProcessRunner.run(
        python,
        arguments: [
          "-B",
          resources.appendingPathComponent("Adapters/install_integrations.py").path, "install",
        ], timeout: 30)
      setupMessage = String(decoding: data, as: UTF8.self)
    } catch { setupMessage = "Setup failed: \(error.localizedDescription)" }
  }
}

struct AgentPanel: View {
  @ObservedObject var model: AgentModel
  @AppStorage("notifyBlocked") private var notifyBlocked = false
  @ViewState private var settings = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("Agent Status", systemImage: "terminal").font(.headline)
        Spacer()
        Button {
          Task { await model.refresh() }
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .help("Refresh now")
        Button {
          settings.toggle()
        } label: {
          Image(systemName: "gearshape")
        }.help("Settings")
      }
      if !model.errors.isEmpty { ErrorBanner(model.errors.joined(separator: "\n")) }
      if settings {
        Toggle("Notify when an agent needs input", isOn: $notifyBlocked)
          .onChange(of: notifyBlocked) { enabled in
            guard enabled else { return }
            Task {
              do {
                let granted = try await Notifications.shared.requestPermission()
                if !granted {
                  notifyBlocked = false
                  model.setupMessage = "Enable notifications in System Settings > Notifications."
                }
              } catch {
                notifyBlocked = false
                model.setupMessage = error.localizedDescription
              }
            }
          }
        Button("Install / update agent integrations") { Task { await model.install() } }
          .disabled(model.installing)
        Text("Preserves existing hooks and Claude status line. Restart agents after setup.")
          .font(.caption).foregroundStyle(.secondary)
      }
      if let message = model.setupMessage {
        Text(message).font(.caption).textSelection(.enabled)
      }
      usagePanel
      Divider()
      if model.active.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Text("No active sessions detected.")
          Text("Install the integrations, then start or restart Pi, Claude Code, or Copilot CLI.")
            .font(.caption).foregroundStyle(.secondary)
          Button("Set up integrations") { Task { await model.install() } }
            .disabled(model.installing)
        }.padding(.vertical, 8)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 10) {
            ForEach(model.active) { session in sessionRow(session) }
          }
        }.frame(maxHeight: 350)
      }
      Text("Local telemetry only. Sessions without recent events become Unknown after 5 minutes.")
        .font(.caption2).foregroundStyle(.secondary)
      Divider()
      AppFooter()
    }.padding(16).frame(width: 410)
  }

  private var usagePanel: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Claude subscription usage").font(.subheadline.bold())
      if let session = model.latestClaudeUsage, let usage = session.usage {
        quotaRow("5 hours", window: usage.fiveHour)
        quotaRow("7 days", window: usage.sevenDay)
        if let updated = session.usageUpdatedAt {
          HStack {
            Text("Last reported")
            Text(Date(timeIntervalSince1970: updated), style: .relative)
            Text("ago")
          }.font(.caption2).foregroundStyle(
            model.now.timeIntervalSince1970 - updated > 300 ? .orange : .secondary)
        }
      } else {
        Text("Unavailable until an eligible Claude Pro/Max session reports quota data.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func quotaRow(_ title: String, window: UsageWindow?) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      if let window, window.isCurrent(at: model.now) {
        HStack {
          Text(title)
          Spacer()
          Text("\(window.usedPercentage, specifier: "%.0f")% used")
        }.font(.caption)
        ProgressView(value: window.usedPercentage, total: 100)
          .tint(window.usedPercentage >= 90 ? .orange : .accentColor)
        HStack {
          Text("Resets")
          Text(Date(timeIntervalSince1970: window.resetsAt), style: .relative)
        }.font(.caption2).foregroundStyle(.secondary)
      } else {
        Text("\(title): unavailable / awaiting fresh quota data")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func sessionRow(_ session: AgentSession) -> some View {
    let state = session.displayedState(at: model.now)
    return VStack(alignment: .leading, spacing: 4) {
      HStack {
        Label(session.agent.capitalized, systemImage: state.symbol).font(.subheadline.bold())
        Spacer()
        Text(state.title).font(.caption)
          .foregroundStyle(state == .blocked ? .orange : state == .working ? .green : .secondary)
      }
      Text(session.project.isEmpty ? "Project unavailable" : session.project)
        .font(.caption).lineLimit(1).truncationMode(.middle).help(session.project)
      if let detail = session.detail, !detail.isEmpty {
        Text(detail).font(.caption2).foregroundStyle(.secondary)
      }
      HStack {
        Text(String(session.sessionID.prefix(8)))
        Spacer()
        Text(session.updatedDate, style: .relative)
        Text("ago")
      }.font(.caption2).foregroundStyle(.secondary)
    }.padding(8).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
  }
}

struct StatusApp: App {
  @StateObject private var model = AgentModel()
  var body: some Scene {
    MenuBarExtra {
      AgentPanel(model: model)
    } label: {
      Label(model.label, systemImage: model.symbol)
    }.menuBarExtraStyle(.window)
  }
}

@main
enum AgentLauncher {
  @MainActor static func main() async {
    if CommandLine.arguments.contains("--smoke-test") {
      let result = SessionReadResult.read()
      guard result.errors.isEmpty else {
        FileHandle.standardError.write(Data((result.errors.joined(separator: "\n") + "\n").utf8))
        exit(1)
      }
      print("AgentStatus: read \(result.sessions.count) session records.")
    } else {
      StatusApp.main()
    }
  }
}
