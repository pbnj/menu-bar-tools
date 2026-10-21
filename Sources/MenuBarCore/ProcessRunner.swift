import Darwin
import Foundation

public struct ToolError: LocalizedError, Sendable {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var errorDescription: String? { message }
}

public enum ProcessRunner {
  public static var searchPath: String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return [
      "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
      ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
    ].joined(separator: ":")
  }

  public static func executable(_ name: String, override: String = "") throws -> URL {
    if !override.isEmpty {
      guard override.hasPrefix("/"),
        FileManager.default.isExecutableFile(atPath: override)
      else {
        throw ToolError("Executable must be an absolute path to an executable file: \(override)")
      }
      return URL(fileURLWithPath: override)
    }
    for directory in searchPath.split(separator: ":") {
      let url = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
      if FileManager.default.isExecutableFile(atPath: url.path) { return url }
    }
    throw ToolError("Cannot find \(name). Install it or set its absolute path in Settings.")
  }

  public static func run(
    _ executable: URL, arguments: [String],
    timeout: TimeInterval = 90
  ) async throws -> Data {
    try await Task.detached(priority: .utility) {
      try runBlocking(executable, arguments: arguments, timeout: timeout)
    }.value
  }

  private static func runBlocking(
    _ executable: URL, arguments: [String],
    timeout: TimeInterval
  ) throws -> Data {
    let manager = FileManager.default
    let directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try manager.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    defer {
      do { try manager.removeItem(at: directory) } catch {
        NSLog("MenuBarTools temporary file cleanup failed: %@", error.localizedDescription)
      }
    }
    let stdout = directory.appendingPathComponent("stdout")
    let stderr = directory.appendingPathComponent("stderr")
    guard manager.createFile(atPath: stdout.path, contents: nil),
      manager.createFile(atPath: stderr.path, contents: nil)
    else {
      throw ToolError("Cannot create command output files.")
    }
    let output = try FileHandle(forWritingTo: stdout)
    let errors = try FileHandle(forWritingTo: stderr)
    defer {
      do {
        try output.close()
        try errors.close()
      } catch { NSLog("MenuBarTools output close failed: %@", error.localizedDescription) }
    }
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = searchPath
    environment["GH_PROMPT_DISABLED"] = "1"
    environment["GH_PAGER"] = "cat"
    environment["NO_COLOR"] = "1"
    process.environment = environment
    process.currentDirectoryURL = manager.homeDirectoryForCurrentUser
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    if process.isRunning {
      process.terminate()
      let grace = Date().addingTimeInterval(2)
      while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.05) }
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
      process.waitUntilExit()
      throw ToolError(
        "Command timed out after \(Int(timeout)) seconds. Check network access and gh authentication."
      )
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      let detail = String(decoding: try Data(contentsOf: stderr), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      throw ToolError("Command exited \(process.terminationStatus): \(detail.prefix(2000))")
    }
    return try Data(contentsOf: stdout)
  }
}
