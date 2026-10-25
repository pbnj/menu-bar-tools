import AppKit
import MenuBarCore
import ServiceManagement
import SwiftUI
import UserNotifications

// Disambiguates the property wrapper from the newer SDK's same-named macro.
public typealias ViewState<Value> = SwiftUI.State<Value>

@MainActor
public final class Notifications: NSObject, UNUserNotificationCenterDelegate {
  public static let shared = Notifications()

  public func requestPermission() async throws -> Bool {
    UNUserNotificationCenter.current().delegate = self
    return try await UNUserNotificationCenter.current().requestAuthorization(options: [
      .alert, .sound,
    ])
  }

  public func send(title: String, body: String, identifier: String) async throws {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    try await UNUserNotificationCenter.current().add(
      UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
  }

  public nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions { [.banner, .sound] }
}

public struct ErrorBanner: View {
  let message: String
  public init(_ message: String) { self.message = message }
  public var body: some View {
    Label(message, systemImage: "exclamationmark.triangle")
      .font(.caption).foregroundStyle(.orange)
      .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
      .padding(8).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
  }
}

public struct LoginItemToggle: View {
  @ViewState private var enabled = SMAppService.mainApp.status == .enabled
  @ViewState private var error: String?
  public init() {}
  public var body: some View {
    VStack(alignment: .leading) {
      Toggle("Launch at login", isOn: $enabled)
        .onChange(of: enabled) { value in
          do {
            if value {
              try SMAppService.mainApp.register()
            } else {
              try SMAppService.mainApp.unregister()
            }
            error =
              SMAppService.mainApp.status == .requiresApproval
              ? "Approve this app in System Settings > General > Login Items." : nil
          } catch {
            self.error = error.localizedDescription
            enabled = SMAppService.mainApp.status == .enabled
          }
        }
      if let error { ErrorBanner(error) }
    }
  }
}

public struct AppFooter: View {
  public init() {}
  public var body: some View {
    HStack {
      LoginItemToggle()
      Spacer()
      Button("Quit") { NSApplication.shared.terminate(nil) }
    }.font(.caption)
  }
}

/// MenuBarExtra labels only honor a single image and text, so custom labels are
/// rendered to an image. It is not a template image, so it can carry color;
/// `content` receives the foreground matching the menu bar's appearance.
public struct RenderedMenuBarLabel<Content: View>: View {
  @Environment(\.colorScheme) private var colorScheme
  private let accessibilityText: String
  private let content: (Color) -> Content

  public init(_ accessibilityText: String, @ViewBuilder content: @escaping (Color) -> Content) {
    self.accessibilityText = accessibilityText
    self.content = content
  }

  public var body: some View {
    let renderer = ImageRenderer(
      content: content(colorScheme == .dark ? .white : .black).frame(height: 22))
    renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
    return Image(nsImage: renderer.nsImage ?? NSImage()).accessibilityLabel(accessibilityText)
  }
}

/// Popover chrome shared by both apps: an opaque background so windows behind the
/// popover don't tint it, a window that tracks the content height, and no focus
/// ring on the first control when it opens.
public struct MenuBarPanelStyle: ViewModifier {
  public func body(content: Content) -> some View {
    content
      .fixedSize(horizontal: false, vertical: true)
      .background(PanelWindowBridge())
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
  }
}

/// MenuBarExtra grows its window when content grows but never shrinks it, leaving
/// translucent bands after e.g. settings close. As a background of the content this
/// view always has the content's size, so it resizes the window to match, keeping
/// the top edge under the menu bar. With Full Keyboard Access on, SwiftUI focuses
/// the first control each time the window becomes key; clearing it on the next run
/// loop turn removes that ring while leaving Tab navigation working.
private struct PanelWindowBridge: NSViewRepresentable {
  func makeNSView(context: Context) -> PanelWindowView { PanelWindowView() }
  func updateNSView(_ view: PanelWindowView, context: Context) {}
}

final class PanelWindowView: NSView {
  private var observer: NSObjectProtocol?

  override func setFrameSize(_ newSize: NSSize) {
    let changed = newSize.height != frame.height
    super.setFrameSize(newSize)
    if changed { DispatchQueue.main.async { self.fitWindow() } }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
    guard let window else { return }
    observer = NotificationCenter.default.addObserver(
      forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
    ) { [weak window] _ in
      DispatchQueue.main.async { _ = window?.makeFirstResponder(nil) }
    }
    fitWindow()
  }

  private func fitWindow() {
    guard let window, frame.height > 0 else { return }
    var windowFrame = window.frame
    let delta = frame.height - window.contentRect(forFrameRect: windowFrame).height
    guard abs(delta) > 0.5 else { return }
    windowFrame.size.height += delta
    windowFrame.origin.y -= delta
    window.setFrame(windowFrame, display: true)
  }
}

extension View {
  public func menuBarPanel() -> some View { modifier(MenuBarPanelStyle()) }
}
