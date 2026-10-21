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
