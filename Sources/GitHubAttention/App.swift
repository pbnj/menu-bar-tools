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
  /// PR ids with a `gh pr merge` in flight.
  @Published private(set) var merging: Set<String> = []
  /// Section-scoped keys the user has already looked at; anything else that
  /// notifies is shown as new. Persisted so new markers survive a relaunch.
  @Published private(set) var seen: Set<String> = []
  private var previousKeys: Set<String>?
  private var previousScope: [String]?

  init() {
    Notifications.shared.onOpen = { [weak self] url in self?.markSeen(url: url) }
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
      let stored = defaults.stringArray(forKey: "seenAttentionKeys")
      let sameScope = defaults.stringArray(forKey: "seenAttentionScope") == options.arguments
      seen = next.reconcileSeen(sameScope ? stored.map(Set.init) : nil)
      defaults.set(options.arguments, forKey: "seenAttentionScope")
      persistSeen()
      if previousScope == options.arguments, let previousKeys, defaults.bool(forKey: "notify") {
        await notify(next.newItems(since: previousKeys))
      }
      previousKeys = keys
      previousScope = options.arguments
    } catch {
      self.error = error.localizedDescription
    }
  }

  /// Merges with the configured method, then refreshes so the PR drops out.
  func merge(_ pr: AttentionPR) async {
    guard pr.browserURL != nil, merging.insert(pr.id).inserted else { return }
    defer { merging.remove(pr.id) }
    let defaults = UserDefaults.standard
    let method = MergeMethod(rawValue: defaults.string(forKey: "mergeMethod") ?? "") ?? .squash
    do {
      let executable = try ProcessRunner.executable(
        "gh", override: defaults.string(forKey: "ghPath") ?? "")
      _ = try await ProcessRunner.run(
        executable,
        arguments: method.arguments(pr, deleteBranch: defaults.bool(forKey: "deleteBranch")))
      error = nil
    } catch {
      self.error = "Merge of \(pr.repo) #\(pr.number) failed: \(error.localizedDescription)"
      return
    }
    await refresh()
  }

  /// One notification per PR, up to a few, then a summary for the rest so a
  /// burst (say, after waking from sleep) doesn't flood Notification Center.
  private func notify(_ items: [(section: AttentionSection, pr: AttentionPR)]) async {
    let limit = 3
    do {
      for (section, pr) in items.prefix(limit) {
        try await Notifications.shared.send(
          title: section.title, subtitle: "\(pr.repo) #\(pr.number)", body: pr.title,
          identifier: section.key(pr), url: pr.browserURL)
      }
      if items.count > limit {
        let more = items.count - limit
        try await Notifications.shared.send(
          title: "GitHub needs your attention",
          body: "\(more) more new attention item\(more == 1 ? "" : "s"). Open the menu bar to review.",
          identifier: UUID().uuidString)
      }
    } catch { self.error = "Notification failed: \(error.localizedDescription)" }
  }

  /// A notification click opens the PR, which counts as having seen it.
  func markSeen(url: URL) {
    if let pr = snapshot?.sections.values.joined().first(where: { $0.browserURL == url }) {
      markSeen(pr)
    }
  }

  var newCount: Int { snapshot.map { $0.notificationKeys.subtracting(seen).count } ?? 0 }

  func isNew(_ pr: AttentionPR, in section: AttentionSection) -> Bool {
    section.notifies && !seen.contains(section.key(pr))
  }

  /// Opening a PR covers it in every section it appears in.
  func markSeen(_ pr: AttentionPR) {
    guard let snapshot else { return }
    for section in AttentionSection.allCases where section.notifies {
      if snapshot[section].contains(where: { $0.id == pr.id }) { seen.insert(section.key(pr)) }
    }
    persistSeen()
  }

  func markAllSeen() {
    guard let snapshot else { return }
    seen = snapshot.notificationKeys
    persistSeen()
  }

  private func persistSeen() {
    UserDefaults.standard.set(Array(seen), forKey: "seenAttentionKeys")
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
  @AppStorage("onlyNew") private var onlyNew = false
  @AppStorage("mergeMethod") private var mergeMethod = MergeMethod.squash.rawValue
  @AppStorage("deleteBranch") private var deleteBranch = false
  @ViewState private var settings = false
  /// PR awaiting a second click to confirm its merge.
  @ViewState private var confirmingMerge: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label { Text("GitHub Attention") } icon: { GitHubMark().frame(width: 15, height: 15) }
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
        if model.newCount > 0 || onlyNew {
          HStack {
            Label("\(model.newCount) new", systemImage: "circle.fill")
              .foregroundStyle(model.newCount > 0 ? Color.accentColor : .secondary)
              .labelStyle(NewLabelStyle())
            Spacer()
            Toggle("Only new", isOn: $onlyNew).toggleStyle(.checkbox)
            Button("Mark all seen") { model.markAllSeen() }.disabled(model.newCount == 0)
          }.font(.caption)
        }
        if snapshot.count == 0 {
          Label("You're all caught up.", systemImage: "checkmark.circle")
            .foregroundStyle(.secondary).padding(.vertical)
        } else {
          // A ScrollView has no ideal height in a MenuBarExtra window, so only
          // scroll once the list would outgrow the popover.
          let visible = Dictionary(
            uniqueKeysWithValues: AttentionSection.allCases.map { section in
              (section, rows(snapshot, section))
            })
          let sections = VStack(alignment: .leading, spacing: 16) {
            ForEach(AttentionSection.allCases, id: \.rawValue) { section in
              if let prs = visible[section], !prs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                  Label("\(section.title) (\(prs.count))", systemImage: section.symbol)
                    .font(.subheadline.bold())
                  ForEach(prs) { pr in
                    row(pr, isNew: model.isNew(pr, in: section), mergeable: section == .approved)
                  }
                }
              }
            }
          }
          let rows = visible.values.reduce(0) { $0 + $1.count }
          if rows == 0 {
            Label("No new items.", systemImage: "checkmark.circle")
              .foregroundStyle(.secondary).padding(.vertical)
          } else if rows > 6 {
            ScrollView { sections }.frame(height: 440)
          } else {
            sections
          }
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
    }.padding(16).frame(width: 430).menuBarPanel()
  }

  /// New items first so they are not buried in long sections; otherwise the
  /// order from `gh attention` is kept.
  private func rows(_ snapshot: AttentionSnapshot, _ section: AttentionSection) -> [AttentionPR] {
    let prs = snapshot[section]
    let new = prs.filter { model.isNew($0, in: section) }
    if onlyNew { return new }
    return new + prs.filter { !model.isNew($0, in: section) }
  }

  private func row(_ pr: AttentionPR, isNew: Bool, mergeable: Bool) -> some View {
    HStack(spacing: 0) {
      link(pr, isNew: isNew)
      if mergeable && pr.browserURL != nil { mergeControl(pr).padding(.trailing, 8) }
    }
    .background(
      isNew ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.04),
      in: RoundedRectangle(cornerRadius: 6)
    )
    .contextMenu {
      if isNew { Button("Mark as seen") { model.markSeen(pr) } }
      if mergeable && pr.browserURL != nil {
        Button("Merge…") { confirmingMerge = pr.id }.disabled(model.merging.contains(pr.id))
      }
    }
  }

  /// Merging can't be undone, so the first click only arms a confirmation.
  @ViewBuilder private func mergeControl(_ pr: AttentionPR) -> some View {
    let method = MergeMethod(rawValue: mergeMethod) ?? .squash
    if model.merging.contains(pr.id) {
      ProgressView().controlSize(.small).help("Merging…")
    } else if confirmingMerge == pr.id {
      HStack(spacing: 4) {
        Button("Cancel") { confirmingMerge = nil }
        Button(method.title) {
          confirmingMerge = nil
          Task { await model.merge(pr) }
        }.buttonStyle(.borderedProminent).tint(.green)
      }.controlSize(.small)
    } else {
      Button {
        confirmingMerge = pr.id
      } label: {
        Image(systemName: "arrow.triangle.merge")
      }.buttonStyle(.borderless).help("\(method.title) \(pr.repo) #\(pr.number)")
        .accessibilityLabel("Merge \(pr.title)")
    }
  }

  private func link(_ pr: AttentionPR, isNew: Bool) -> some View {
    Button {
      model.markSeen(pr)
      if let url = pr.browserURL { NSWorkspace.shared.open(url) }
    } label: {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Circle().fill(Color.accentColor).frame(width: 7, height: 7)
          .opacity(isNew ? 1 : 0).accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 3) {
          Text(pr.title).fontWeight(isNew ? .semibold : .regular)
            .lineLimit(2).multilineTextAlignment(.leading)
          Text(verbatim: "\(pr.repo) #\(pr.number)").font(.caption).foregroundStyle(.secondary)
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
        .padding(8).contentShape(Rectangle())
    }.buttonStyle(.plain).disabled(pr.browserURL == nil)
      .accessibilityLabel(isNew ? "New: \(pr.title)" : pr.title)
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
      Picker("Merge approved PRs with", selection: $mergeMethod) {
        ForEach(MergeMethod.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
      }
      Toggle("Delete branch after merge", isOn: $deleteBranch)
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
      let count = model.snapshot?.count
      RenderedMenuBarLabel(
        model.error.map { "GitHub Attention error: \($0)" }
          ?? count.map { "GitHub Attention, \($0) pull requests" } ?? "GitHub Attention, loading"
      ) { foreground in
        HStack(spacing: 3) {
          GitHubMark().foregroundStyle(foreground).frame(width: 16, height: 16)
          if model.error != nil {
            CountBadge(text: "!", color: .orange)
          } else if let count, count > 0 {
            CountBadge(text: "\(count)", color: .red)
          }
        }
      }
    }.menuBarExtraStyle(.window)
  }
}

/// Small accent dot in front of the "N new" summary.
struct NewLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 4) {
      configuration.icon.font(.system(size: 6))
      configuration.title
    }
  }
}

/// Notification-style pill holding the total count.
struct CountBadge: View {
  let text: String
  let color: Color

  var body: some View {
    Text(text)
      .font(.system(size: 10, weight: .bold).monospacedDigit())
      .foregroundStyle(.white)
      .padding(.horizontal, 4)
      .frame(minWidth: 15, minHeight: 15)
      .background(color, in: Capsule())
  }
}

/// GitHub's mark from Octicons (MIT, https://github.com/primer/octicons).
/// SVG data loads natively on macOS 14+; older systems fall back to a symbol.
struct GitHubMark: View {
  private static let image: NSImage? = {
    let svg = #"""
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="16" height="16"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"/></svg>
      """#
    let image = NSImage(data: Data(svg.utf8))
    image?.isTemplate = true
    return image
  }()

  var body: some View {
    if let image = Self.image {
      Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
    } else {
      Image(systemName: "chevron.left.forwardslash.chevron.right").resizable().scaledToFit()
    }
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
      Notifications.shared.activate()
      AttentionApp.main()
    }
  }
}
