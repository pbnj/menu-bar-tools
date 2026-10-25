import AppKit
import MenuBarCore
import MenuBarUI
import SwiftUI

@MainActor
final class AgentModel: ObservableObject {
  @Published var sessions: [AgentSession] = []
  @Published var panes: [ClaudePane] = []
  @Published var jumpError: String?
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

  /// Most urgent state across live Claude sessions, or nil when none are running.
  var overallState: AgentState? {
    let states = panes.map { $0.state(at: now) }
    for state in [AgentState.blocked, .working, .idle, .unknown] where states.contains(state) {
      return state
    }
    return nil
  }
  var latestClaudeUsage: AgentSession? {
    sessions.filter { $0.agent == "claude" && $0.usage != nil && $0.usageUpdatedAt != nil }
      .max { ($0.usageUpdatedAt ?? 0) < ($1.usageUpdatedAt ?? 0) }
  }

  func refresh() async {
    let result = await Task.detached(priority: .utility) { SessionReadResult.read() }.value
    let processes = await Self.claudeProcesses()
    let tmuxPanes = await Self.tmuxPanes()
    now = Date()
    sessions = result.sessions
    errors = result.errors
    panes = ClaudePane.join(processes: processes, panes: tmuxPanes, sessions: sessions)
    var states: [String: AgentState] = [:]
    for session in sessions where session.agent == "claude" {
      let state = session.displayedState(at: now)
      states[session.id] = state
      if loaded && state == .blocked && previousStates[session.id] != .blocked
        && UserDefaults.standard.bool(forKey: "notifyBlocked")
      {
        do {
          try await Notifications.shared.send(
            title: "Claude needs input",
            body: URL(fileURLWithPath: session.project).lastPathComponent,
            identifier: session.id)
        } catch { errors.append("Notification failed: \(error.localizedDescription)") }
      }
    }
    previousStates = states
    loaded = true
  }

  private static func claudeProcesses() async -> [ClaudeProcess] {
    do {
      let data = try await ProcessRunner.run(
        URL(fileURLWithPath: "/bin/ps"), arguments: ClaudeProcess.listArguments, timeout: 5)
      return ClaudeProcess.parse(String(decoding: data, as: UTF8.self))
    } catch { return [] }
  }

  // No tmux binary or no running server both mean "no panes", not an error.
  private static func tmuxPanes() async -> [TmuxPane] {
    do {
      let tmux = try ProcessRunner.executable("tmux")
      let data = try await ProcessRunner.run(tmux, arguments: TmuxPane.listArguments, timeout: 5)
      return TmuxPane.parse(String(decoding: data, as: UTF8.self))
    } catch { return [] }
  }

  func jump(to pane: TmuxPane) async {
    jumpError = nil
    do {
      let tmux = try ProcessRunner.executable("tmux")
      let data = try await ProcessRunner.run(tmux, arguments: TmuxClient.listArguments, timeout: 5)
      let clients = TmuxClient.parse(String(decoding: data, as: UTF8.self))
      guard !clients.isEmpty else {
        throw ToolError("No tmux client is attached. Attach to tmux in Ghostty first.")
      }
      for arguments in TmuxClient.jumpCommands(to: pane, clients: clients) {
        _ = try await ProcessRunner.run(tmux, arguments: arguments, timeout: 5)
      }
      guard
        let ghostty = NSWorkspace.shared.urlForApplication(
          withBundleIdentifier: "com.mitchellh.ghostty")
      else { throw ToolError("Ghostty is not installed.") }
      try await NSWorkspace.shared.openApplication(
        at: ghostty, configuration: NSWorkspace.OpenConfiguration())
    } catch { jumpError = "Cannot switch to \(pane.target): \(error.localizedDescription)" }
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
  @AppStorage("meterStyle") private var meterStyle = MeterStyle.barsAndPercentages
  @ViewState private var settings = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label { Text("Claude Status") } icon: { ClaudeMark().frame(width: 14, height: 14) }.font(.headline)
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
      if let error = model.jumpError { ErrorBanner(error) }
      if settings {
        Toggle("Notify when Claude needs input", isOn: $notifyBlocked)
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
        Picker("Menu bar usage", selection: $meterStyle) {
          ForEach(MeterStyle.allCases, id: \.self) { Text($0.title).tag($0) }
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
      if model.panes.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Text("No running Claude Code sessions.")
          Text("Install the integrations so sessions report working, idle, and needs input.")
            .font(.caption).foregroundStyle(.secondary)
          Button("Set up integrations") { Task { await model.install() } }
            .disabled(model.installing)
        }.padding(.vertical, 8)
      } else {
        // A ScrollView has no ideal height in a MenuBarExtra window, so only
        // scroll once the list would outgrow the popover.
        let rows = VStack(alignment: .leading, spacing: 6) {
          ForEach(model.panes) { pane in paneRow(pane) }
        }
        if model.panes.count > 6 {
          ScrollView { rows }.frame(height: 350)
        } else {
          rows
        }
      }
      Text("Click a session to open its tmux window in Ghostty. Sessions without recent events become Unknown after 5 minutes.")
        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      Divider()
      AppFooter()
    }.padding(16).frame(width: 410).menuBarPanel()
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

  private func paneRow(_ pane: ClaudePane) -> some View {
    let state = pane.state(at: model.now)
    let name = URL(fileURLWithPath: pane.project).lastPathComponent
    return Button {
      guard let tmux = pane.pane else { return }
      Task { await model.jump(to: tmux) }
    } label: {
      HStack(spacing: 8) {
        Circle().fill(state.color ?? (state == .idle ? .primary : .secondary))
          .frame(width: 8, height: 8)
        VStack(alignment: .leading, spacing: 2) {
          Text(name.isEmpty ? "Claude" : name).font(.subheadline.bold())
          Text(pane.project).font(.caption).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle)
        }
        Spacer()
        VStack(alignment: .trailing, spacing: 2) {
          Text(pane.pane.map { "\($0.target) \($0.windowName)" } ?? "Not in tmux")
            .font(.caption.monospaced()).lineLimit(1)
          Text(state.title).font(.caption).foregroundStyle(state.color ?? .secondary)
        }
      }
      .padding(8).contentShape(Rectangle())
      .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }
    .buttonStyle(.plain).disabled(pane.pane == nil)
    .help(pane.pane == nil ? "This session is not running inside tmux." : pane.project)
  }
}

extension AgentState {
  /// nil means the normal foreground color: white on a dark menu bar.
  var color: Color? {
    switch self {
    case .working: .orange
    case .blocked: .red
    case .idle, .unknown, .ended: nil
    }
  }
}

enum MeterStyle: String, CaseIterable {
  case barsAndPercentages, bars, percentages, hidden

  var title: String {
    switch self {
    case .barsAndPercentages: "Bars and percentages"
    case .bars: "Bars"
    case .percentages: "Percentages"
    case .hidden: "Icon only"
    }
  }
  var showsBar: Bool { self == .barsAndPercentages || self == .bars }
  var showsPercentage: Bool { self == .barsAndPercentages || self == .percentages }
}

// Approximation of the Claude spark: tapered rays of uneven length around a hub.
struct ClaudeMark: Shape {
  func path(in rect: CGRect) -> Path {
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let radius = min(rect.width, rect.height) / 2
    let lengths: [CGFloat] = [1, 0.8, 0.96, 0.74, 1, 0.84, 0.9, 0.72, 0.98, 0.8, 0.93, 0.76]
    func point(_ angle: CGFloat, _ distance: CGFloat) -> CGPoint {
      CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance)
    }
    var path = Path()
    for (index, length) in lengths.enumerated() {
      let angle = CGFloat(index) / CGFloat(lengths.count) * 2 * .pi - .pi / 2 + 0.12
      let tip = point(angle, radius * length)
      let side = angle + .pi / 2
      path.move(to: point(side, radius * 0.14))
      path.addLine(to: CGPoint(x: tip.x + cos(side) * radius * 0.05, y: tip.y + sin(side) * radius * 0.05))
      path.addLine(to: CGPoint(x: tip.x - cos(side) * radius * 0.05, y: tip.y - sin(side) * radius * 0.05))
      path.addLine(to: point(side + .pi, radius * 0.14))
      path.closeSubpath()
    }
    path.addEllipse(in: CGRect(x: center.x - radius * 0.2, y: center.y - radius * 0.2,
      width: radius * 0.4, height: radius * 0.4))
    return path
  }
}

// Claude icon colored by session state, followed by Stats.app-style stacked usage meters.
struct MenuBarLabel: View {
  let usage: AgentUsage?
  let style: MeterStyle
  let state: AgentState?
  let now: Date
  let foreground: Color

  var body: some View {
    HStack(spacing: 4) {
      ClaudeMark().fill(state?.color ?? foreground.opacity(state == nil ? 0.5 : 1))
        .frame(width: 15, height: 15)
      if let usage, style != .hidden {
        VStack(alignment: .leading, spacing: 1) {
          meterRow("5h", window: usage.fiveHour)
          meterRow("7d", window: usage.sevenDay)
        }
      }
    }
    .foregroundStyle(foreground)
  }

  private func meterRow(_ title: String, window: UsageWindow?) -> some View {
    let used = window.flatMap { $0.isCurrent(at: now) ? $0.usedPercentage : nil }
    return HStack(spacing: 3) {
      Text(title).font(.system(size: 8, weight: .medium)).frame(width: 11, alignment: .leading)
      if style.showsBar {
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: 1.5).opacity(0.25)
          RoundedRectangle(cornerRadius: 1.5).frame(width: 26 * (used ?? 0) / 100)
        }.frame(width: 26, height: 5)
      }
      if style.showsPercentage || used == nil {
        Text(used.map { "\(Int($0.rounded()))%" } ?? "–")
          .font(.system(size: 8, weight: .semibold).monospacedDigit())
          .frame(width: 22, alignment: .trailing)
      }
    }.frame(height: 9)
  }

  var accessibilityText: String {
    var parts = ["Claude", state?.title ?? "no sessions"]
    for (title, window) in [("5 hour", usage?.fiveHour), ("7 day", usage?.sevenDay)] {
      if let window, window.isCurrent(at: now) {
        parts.append("\(title) usage \(Int(window.usedPercentage.rounded())) percent")
      }
    }
    return parts.joined(separator: ", ")
  }
}

struct StatusApp: App {
  @StateObject private var model = AgentModel()
  @AppStorage("meterStyle") private var meterStyle = MeterStyle.barsAndPercentages
  var body: some Scene {
    MenuBarExtra {
      AgentPanel(model: model)
    } label: {
      StatusItemLabel(model: model, style: meterStyle)
    }.menuBarExtraStyle(.window)
  }
}

struct StatusItemLabel: View {
  @ObservedObject var model: AgentModel
  let style: MeterStyle

  var body: some View {
    let label = { (foreground: Color) in
      MenuBarLabel(
        usage: model.latestClaudeUsage?.usage, style: style, state: model.overallState,
        now: model.now, foreground: foreground)
    }
    RenderedMenuBarLabel(label(.primary).accessibilityText) { label($0) }
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
      print("ClaudeStatus: read \(result.sessions.count) session records.")
    } else if CommandLine.arguments.contains("--list-sessions") {
      let model = AgentModel()
      await model.refresh()
      for pane in model.panes {
        print(pane.pid, pane.pane?.target ?? "-", pane.state(at: model.now).title, pane.project)
      }
    } else {
      StatusApp.main()
    }
  }
}
