import Foundation

public struct AttentionPR: Codable, Identifiable, Sendable {
  public let number: Int
  public let title: String
  public let repo: String
  public let url: String
  public var id: String { url }
  public var browserURL: URL? {
    guard let parsed = URL(string: url),
      ["https", "http"].contains(parsed.scheme), parsed.host != nil
    else { return nil }
    return parsed
  }
}

public enum AttentionSection: String, CaseIterable, Sendable {
  case requested, feedback, failing, approved, review

  public var title: String {
    switch self {
    case .requested: "Review requested"
    case .feedback: "Feedback to address"
    case .failing: "Failing checks"
    case .approved: "Approved"
    case .review: "Awaiting review"
    }
  }

  public var symbol: String {
    switch self {
    case .requested: "person.crop.circle.badge.exclamationmark"
    case .feedback: "text.bubble"
    case .failing: "xmark.circle"
    case .approved: "checkmark.circle"
    case .review: "clock"
    }
  }

  /// Awaiting review is the user's own PRs waiting on others, so it never
  /// notifies or counts as new.
  public var notifies: Bool { self != .review }

  /// Identity of one PR within one section; a PR moving sections is new again.
  public func key(_ pr: AttentionPR) -> String { "\(rawValue):\(pr.id)" }
}

public struct AttentionSnapshot: Sendable {
  public let sections: [String: [AttentionPR]]

  public init(data: Data) throws {
    let decoded = try JSONDecoder().decode([String: [AttentionPR]].self, from: data)
    for section in [AttentionSection.approved, .feedback, .failing, .review] {
      guard decoded[section.rawValue] != nil else {
        throw ToolError(
          "gh attention returned an incomplete response (missing \(section.rawValue)).")
      }
    }
    sections = decoded
  }

  public subscript(section: AttentionSection) -> [AttentionPR] {
    sections[section.rawValue] ?? []
  }

  public var count: Int { Set(sections.values.flatMap { $0.map(\.id) }).count }

  public var notificationKeys: Set<String> {
    Set(
      AttentionSection.allCases.filter(\.notifies).flatMap { section in
        self[section].map(section.key)
      })
  }

  /// Items whose section key is missing from `previous`, in section order.
  /// A PR that lands in several sections at once is reported only once.
  public func newItems(since previous: Set<String>) -> [(
    section: AttentionSection, pr: AttentionPR
  )] {
    var ids = Set<String>()
    var items: [(section: AttentionSection, pr: AttentionPR)] = []
    for section in AttentionSection.allCases where section.notifies {
      for pr in self[section] where !previous.contains(section.key(pr)) {
        if ids.insert(pr.id).inserted { items.append((section, pr)) }
      }
    }
    return items
  }

  /// Carries the seen set forward to this snapshot. With no prior state (first
  /// launch or a changed scope) everything counts as seen, so only items that
  /// appear afterwards are marked new. Items that drop out are forgotten, so
  /// one that comes back is new again, matching notifications.
  public func reconcileSeen(_ seen: Set<String>?) -> Set<String> {
    guard let seen else { return notificationKeys }
    return seen.intersection(notificationKeys)
  }
}

public struct AttentionOptions: Sendable {
  public var organizations: String
  public var repositories: String
  public var includeReviews: Bool
  public var noDrafts: Bool

  public init(
    organizations: String = "", repositories: String = "",
    includeReviews: Bool = true, noDrafts: Bool = false
  ) {
    self.organizations = organizations
    self.repositories = repositories
    self.includeReviews = includeReviews
    self.noDrafts = noDrafts
  }

  public var arguments: [String] {
    var args = ["attention", "--all", "--json"]
    if includeReviews { args.append("--reviews") }
    if noDrafts { args.append("--no-drafts") }
    for org in organizations.split(separator: ",") {
      let value = org.trimmingCharacters(in: .whitespacesAndNewlines)
      if !value.isEmpty { args += ["--org", value] }
    }
    for repo in repositories.split(separator: ",") {
      let value = repo.trimmingCharacters(in: .whitespacesAndNewlines)
      if !value.isEmpty { args += ["--repo", value] }
    }
    return args
  }
}
