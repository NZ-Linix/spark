import Foundation

/** What the bridge sends, mirrored from `mobile/bridge/protocol.ts`. */

nonisolated struct Item: Codable, Identifiable, Hashable, Sendable {
  enum Role: String, Codable, Sendable { case user, assistant, thought, tool, notice }
  enum Status: String, Codable, Sendable { case pending, in_progress, completed, failed }

  var id: String
  var role: Role
  var text: String
  var name: String?
  var title: String?
  var kind: String?
  var status: Status?
  var detail: String?
  var output: String?
}

nonisolated struct ConfigOption: Codable, Identifiable, Hashable, Sendable {
  struct Choice: Codable, Hashable, Sendable {
    var value: String
    var name: String
    var description: String?
  }

  var id: String
  var name: String
  var category: String?
  var currentValue: String
  var options: [Choice]

  var current: Choice? { options.first { $0.value == currentValue } }
}

/** A model id is only unique within a provider. Keep its route and configuration together. */
nonisolated struct ModelChoice: Identifiable {
  struct ID: Hashable {
    let provider: String?
    let model: String
  }

  let model: ConfigOption.Choice
  let config: [ConfigOption]

  private var providerOption: ConfigOption? { config.first { $0.id == "provider" } }
  var provider: String? { providerOption?.currentValue }
  var providerName: String? { providerOption?.current?.name ?? provider }
  var id: ID { ID(provider: provider, model: model.value) }
}

nonisolated struct Permission: Codable, Identifiable, Hashable, Sendable {
  struct Option: Codable, Hashable, Sendable {
    var optionId: String
    var name: String
    var kind: String
  }

  var id: String
  var title: String
  var detail: String?
  var kind: String?
  var options: [Option]
}

nonisolated struct SessionInfo: Codable, Identifiable, Hashable, Sendable {
  var id: String
  var title: String
  var cwd: String
  var updatedAt: String
  var live: Bool
  var running: Bool
  /** "phone": started here. "mac": open in spark on the Mac, such as in a terminal. Older bridges send none. */
  var origin: String?
  /** started without a folder: it runs in one of its own, which goes when the chat is deleted */
  var scratch: Bool? = nil

  var updated: Date { Self.parse(updatedAt) ?? .distantPast }
  var inTerminal: Bool { origin == "mac" }
  var ownFolder: Bool { scratch == true }
  var folder: String { ownFolder ? "no folder" : cwd.split(separator: "/").last.map(String.init) ?? cwd }

  private static func parse(_ s: String) -> Date? {
    try? Date(s, strategy: .iso8601)
  }
}

nonisolated struct Snapshot: Codable, Sendable {
  var id: String
  var title: String
  var cwd: String
  var updatedAt: String
  var live: Bool
  var running: Bool
  var origin: String?
  var scratch: Bool?
  /** open in another spark process on the host, such as a terminal: the phone can read it, not write */
  var elsewhere: Bool?
  var terminalOwner: String?
  var terminalRevision: String?
  var items: [Item]
  var config: [ConfigOption]
  var permission: Permission?
  var usage: Usage?
  /** the library prompt the session runs with; none for spark's own */
  var prompt: String?
  var mcpDisabled: [String]?
  /** after a rewind to just before a message: that message's text, for the composer */
  var restored: String?

  var info: SessionInfo { SessionInfo(id: id, title: title, cwd: cwd, updatedAt: updatedAt, live: live, running: running, origin: origin, scratch: scratch) }
}

nonisolated struct Usage: Codable, Hashable, Sendable {
  var used: Int
  var size: Int
}

nonisolated struct Folder: Codable, Identifiable, Hashable, Sendable {
  var name: String
  var path: String
  var git: Bool
  var id: String { path }
}

nonisolated struct Listing: Codable, Sendable {
  var path: String
  var name: String
  var parent: String?
  var folders: [Folder]
}

nonisolated struct HostEntry: Codable, Identifiable, Hashable, Sendable {
  enum Kind: String, Codable, Sendable { case mac, cloud }
  var id: String
  var name: String
  var kind: Kind
  var online: Bool
  var sharedAccounts: Bool?

  var symbol: String { kind == .cloud ? "cloud" : "laptopcomputer" }
}

nonisolated struct HostHello: Codable, Sendable {
  var name: String
  var kind: String
  var home: String
  var platform: String
}

/** A session in the sidebar, with the host it runs on. */
nonisolated struct Listed: Identifiable, Hashable, Sendable {
  var host: HostEntry
  var session: SessionInfo
  var id: String { "\(host.id)/\(session.id)" }
}

/** One provider in a host's spark settings, as `providers` lists it. */
nonisolated struct ProviderSummary: Codable, Identifiable, Hashable, Sendable {
  var name: String
  /** the name menus show, such as "OpenCode Go" for oc-go */
  var displayName: String?
  var `protocol`: String
  var baseUrl: String
  /** none, key, or bearer */
  var auth: String
  var keyHint: String?
  var keyEnv: String?
  var headerEnv: [String]
  var models: [String]
  var model: String?
  var active: Bool
  /** the whole provider as settings.json holds it, with its key left out */
  var provider: [String: JSON]
  var id: String { name }
  var title: String { displayName ?? name }
}

/** One prompt in the shared library: a whole system prompt a new chat can start with. */
nonisolated struct PromptSummary: Codable, Identifiable, Hashable, Sendable {
  var name: String
  var text: String
  var updatedAt: String
  var id: String { name }
}

/**
 * One MCP server in the shared library, as mcp.json holds it. An env or header value that may be a
 * secret comes as null, with its last 4 characters in `hints` under "env.NAME" or "headers.NAME".
 */
nonisolated struct McpSummary: Codable, Identifiable, Hashable, Sendable {
  var name: String
  var server: [String: JSON]
  var hints: [String: String]
  var id: String { name }
  var enabled: Bool { server["enabled"] != .bool(false) }
  var url: String? { if case .string(let u) = server["url"] { u } else { nil } }
  var command: String? { if case .string(let c) = server["command"] { c } else { nil } }
  var args: [String] {
    guard case .array(let a) = server["args"] else { return [] }
    return a.compactMap { if case .string(let s) = $0 { s } else { nil } }
  }
  /** the one line a list shows: where it connects, or what it runs */
  var detail: String { url ?? ([command ?? ""] + args).joined(separator: " ") }
}

/** One message from the bridge, with every field any kind might carry. */
nonisolated struct Event: Decodable, Sendable {
  var t: String
  var id: JSON?
  var ok: Bool?
  var result: JSON?
  var error: String?
  var s: String?
  var item: Item?
  var text: String?
  var running: Bool?
  var reason: String?
  var title: String?
  var updatedAt: String?
  var config: [ConfigOption]?
  var used: Int?
  var size: Int?
  var permission: Permission?
  /** a terminal command's output: `data` as it comes, then `done` with its exit `code` and `cwd` */
  var run: String?
  var data: String?
  var done: Bool?
  var code: Int?
  var cwd: String?
}

nonisolated struct Envelope: Decodable, Sendable {
  var host: String?
  var relay: String?
  var hosts: [HostEntry]?
  var msg: Event?
}

/** Any JSON, kept so a reply's result can be decoded once its type is known. */
nonisolated enum JSON: Codable, Hashable, Sendable {
  case null, bool(Bool), number(Double), string(String), array([JSON]), object([String: JSON])

  init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() { self = .null }
    else if let b = try? c.decode(Bool.self) { self = .bool(b) }
    else if let n = try? c.decode(Double.self) { self = .number(n) }
    else if let s = try? c.decode(String.self) { self = .string(s) }
    else if let a = try? c.decode([JSON].self) { self = .array(a) }
    else { self = .object(try c.decode([String: JSON].self)) }
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .null: try c.encodeNil()
    case .bool(let b): try c.encode(b)
    case .number(let n): try c.encode(n)
    case .string(let s): try c.encode(s)
    case .array(let a): try c.encode(a)
    case .object(let o): try c.encode(o)
    }
  }

  var int: Int? { if case .number(let n) = self { Int(n) } else { nil } }

  func decode<T: Decodable>(_ type: T.Type) throws -> T {
    try JSONDecoder().decode(T.self, from: JSONEncoder().encode(self))
  }
}
