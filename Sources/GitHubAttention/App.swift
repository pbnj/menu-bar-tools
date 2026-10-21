import AppKit
import MenuBarCore
import MenuBarUI
import SwiftUI

@MainActor
final class AttentionModel: ObservableObject {
  @Published var snapshot: AttentionSnapshot?
  @Published var error: String?
  @Published var refreshing = false
  @Published var updatedAt: Date?
  private var previousKeys: Set<String>?
  private var previousScope: [String]?

  init() {
    UserDefaults.standard.register(defaults: ["includeReviews": true, "refreshSeconds": 120])
    Task {
      while !Task.isCancelled {
        await refresh()
        let interval = max(60, UserDefaults.standard.integer(forKey: "refreshSeconds"))
        do { try await Task.sleep(for: .seconds(interval)) } catch { break }
      }
    }
  }

  func refresh() async {
    guard !refreshing else { return }
    refreshing = true
    defer { refreshing = false }
    let defaults = UserDefaults.standard
    let options = AttentionOptions(
      organizations: defaults.string(forKey: "organizations") ?? "",
      repositories: defaults.string(forKey: "repositories") ?? "",
      includeReviews: defaults.bool(forKey: "includeReviews"),
      noDrafts: defaults.bool(forKey: "noDrafts"))
    do {
      let executable = try ProcessRunner.executable(
        "gh", override: defaults.string(forKey: "ghPath") ?? "")
      let data = try await ProcessRunner.run(executable, arguments: options.arguments)
      let next = try AttentionSnapshot(data: data)
      snapshot = next
      updatedAt = Date()
      error = nil
      let keys = next.notificationKeys
      if previousScope == options.arguments, let previousKeys, defaults.bool(forKey: "notify") {
        let added = keys.subtracting(previousKeys).count
        if added > 0 {
          do {
            try await Notifications.shared.send(
              title: "GitHub needs your attention",
              body:
                "\(added) new attention item\(added == 1 ? "" : "s"). Open the menu bar to review.",
              identifier: UUID().uuidString)
          } catch { self.error = "Notification failed: \(error.localizedDescription)" }
        }
      }
      previousKeys = keys
      previousScope = options.arguments
    } catch {
      self.error = error.localizedDescription
    }
  }
}

struct AttentionPanel: View {
  @ObservedObject var model: AttentionModel
  @AppStorage("organizations") private var organizations = ""
  @AppStorage("repositories") private var repositories = ""
  @AppStorage("includeReviews") private var includeReviews = true
  @AppStorage("noDrafts") private var noDrafts = false
  @AppStorage("refreshSeconds") private var refreshSeconds = 120
  @AppStorage("ghPath") private var ghPath = ""
  @AppStorage("notify") private var notify = false
  @ViewState private var settings = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("GitHub Attention", systemImage: "tray.full")
          .font(.headline)
        Spacer()
        if model.refreshing { ProgressView().controlSize(.small) }
        Button {
          Task { await model.refresh() }
        } label: {
          Image(systemName: "arrow.clockwise")
        }.disabled(model.refreshing).help("Refresh now")
        Button {
          settings.toggle()
        } label: {
          Image(systemName: "gearshape")
        }
        .help("Settings")
      }
      if let error = model.error { ErrorBanner(error) }
      if settings { preferences }
      if let snapshot = model.snapshot {
        if snapshot.count == 0 {
          Label("You're all caught up.", systemImage: "checkmark.circle")
            .foregroundStyle(.secondary).padding(.vertical)
        } else {
          ScrollView {
            VStack(alignment: .leading, spacing: 16) {
              ForEach(AttentionSection.allCases, id: \.rawValue) { section in
                if !snapshot[section].isEmpty {
                  VStack(alignment: .leading, spacing: 6) {
                    Label(
                      "\(section.title) (\(snapshot[section].count))", systemImage: section.symbol
                    )
                    .font(.subheadline.bold())
                    ForEach(snapshot[section]) { pr in
                      Button {
                        if let url = pr.browserURL { NSWorkspace.shared.open(url) }
                      } label: {
                        VStack(alignment: .leading, spacing: 3) {
                          Text(pr.title).lineLimit(2).multilineTextAlignment(.leading)
                          Text("\(pr.repo) #\(pr.number)").font(.caption).foregroundStyle(
                            .secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                          .padding(8).contentShape(Rectangle())
                      }.buttonStyle(.plain).disabled(pr.browserURL == nil)
                        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                    }
                  }
                }
              }
            }
          }.frame(maxHeight: 440)
        }
      } else if model.refreshing {
        Text("Fetching pull requests...").foregroundStyle(.secondary)
      }
      if let updatedAt = model.updatedAt {
        HStack {
          Text(model.error == nil ? "Updated" : "Showing cached result from")
          Text(updatedAt, style: .relative)
          Text("ago")
        }.font(.caption).foregroundStyle(.secondary)
      }
      Divider()
      AppFooter()
    }.padding(16).frame(width: 430)
  }

  private var preferences: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField("Organizations (comma-separated, blank = all)", text: $organizations)
      TextField("Repositories (owner/repo, comma-separated)", text: $repositories)
      TextField("gh executable (blank = auto-detect)", text: $ghPath)
      Toggle("Include requests for my review", isOn: $includeReviews)
      Toggle("Exclude drafts", isOn: $noDrafts)
      Stepper(
        "Refresh every \(refreshSeconds) seconds", value: $refreshSeconds, in: 60...900, step: 30)
      Toggle("Notify about new attention items", isOn: $notify)
        .onChange(of: notify) { enabled in
          guard enabled else { return }
          Task {
            do {
              let granted = try await Notifications.shared.requestPermission()
              if !granted {
                notify = false
                model.error =
                  "Notifications are disabled. Enable them in System Settings > Notifications."
              }
            } catch {
              notify = false
              model.error = error.localizedDescription
            }
          }
        }
      Button("Apply and refresh") { Task { await model.refresh() } }
    }.font(.caption).textFieldStyle(.roundedBorder)
  }
}

struct AttentionApp: App {
  @StateObject private var model = AttentionModel()
  var body: some Scene {
    MenuBarExtra {
      AttentionPanel(model: model)
    } label: {
      Label(
        model.snapshot.map { "\($0.count)" } ?? (model.error == nil ? "..." : "!"),
        systemImage: model.error == nil ? "tray.full" : "exclamationmark.triangle")
    }.menuBarExtraStyle(.window)
  }
}

@main
enum AttentionLauncher {
  @MainActor static func main() async {
    if CommandLine.arguments.contains("--smoke-test") {
      do {
        let gh = try ProcessRunner.executable("gh")
        let data = try await ProcessRunner.run(gh, arguments: AttentionOptions().arguments)
        let snapshot = try AttentionSnapshot(data: data)
        print("GitHubAttention: decoded \(snapshot.count) unique pull requests.")
      } catch {
        FileHandle.standardError.write(
          Data("GitHubAttention: \(error.localizedDescription)\n".utf8))
        exit(1)
      }
    } else {
      AttentionApp.main()
    }
  }
}
