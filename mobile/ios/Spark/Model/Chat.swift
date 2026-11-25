import Foundation
import Observation

/**
 * One message or tool call in a chat. Each is its own observable, so text streaming into one row
 * redraws that row alone and the thread around it stays put.
 */
@Observable
final class Entry: Identifiable {
  let id: String
  /** fixed for the row's life: the thread lays rows out by role without watching their text */
  let role: Item.Role
  var item: Item
  /** when it came in live while spark works; nil for rows loaded with the chat */
  @ObservationIgnored var arrived: Date?
  /** just came in, so it animates in the first time it's drawn */
  var fresh: Bool { arrived.map { $0.timeIntervalSinceNow > -1 } ?? false }

  init(_ item: Item) {
    id = item.id
    role = item.role
    self.item = item
  }
}

/** One open session: its messages as they stream in, whether spark is working, and what it's asking. */
@Observable
final class Chat {
  let host: String
  var info: SessionInfo
  private(set) var entries: [Entry] = []
  var running = false
  var config: [ConfigOption] = []
  var permission: Permission?
  var usage: Usage?
  var loaded = false
  var problem: String?
  /** The terminal owns this chat. Without a live owner token, it is read-only. */
  var elsewhere = false
  var terminalOwner: String?
  var terminalRevision: String?
  var sending = false
  var canSend: Bool { !sending && (!elsewhere || terminalOwner != nil) && (!running || terminalOwner != nil) }
  /** a chat the phone shows before its session exists: its first message waits for the host */
  var starting = false
  /** bumped when a reply finishes, for the haptic */
  var finished = 0
  /** the library prompt the chat runs with; empty for spark's own */
  var prompt = ""
  var mcpDisabled: Set<String> = []
  var changingMcp = false
  /** bumped when the chat goes back to an earlier message: the thread is laid out afresh */
  var epoch = 0
  /** going back to an earlier message: the thread waits for the host */
  var rewinding = false

  @ObservationIgnored private var index: [String: Int] = [:]

  init(host: String, info: SessionInfo) {
    self.host = host
    self.info = info
    self.running = info.running
  }

  var key: String { "\(host)/\(info.id)" }
  var isEmpty: Bool { entries.isEmpty }

  func load(_ s: Snapshot) {
    info = s.info
    running = s.running
    config = s.config
    permission = s.permission
    usage = s.usage
    elsewhere = s.elsewhere ?? false
    terminalOwner = s.terminalOwner
    terminalRevision = s.terminalRevision
    prompt = s.prompt ?? ""
    mcpDisabled = Set(s.mcpDisabled ?? [])
    // rows the phone already shows keep their objects, so reopening doesn't redraw the thread
    var next: [Entry] = []
    next.reserveCapacity(s.items.count)
    for item in s.items {
      if let i = index[item.id], entries[i].role == item.role {
        if entries[i].item != item { entries[i].item = item }
        next.append(entries[i])
      } else {
        next.append(Entry(item))
      }
    }
    if entries.count != next.count || !zip(entries, next).allSatisfy({ $0 === $1 }) {
      entries = next
      reindex()
    }
    loaded = true
  }

  /** the session now exists on the host: take its id and options, keep what's shown */
  func adopt(_ s: Snapshot) {
    // the host names a session only once its first turn ends; until then the phone's title stays
    let title = info.title
    info = s.info
    if !title.isEmpty { info.title = title }
    config = s.config
    usage = s.usage
    mcpDisabled = Set(s.mcpDisabled ?? [])
    starting = false
  }

  /** the chat as it stands after going back to an earlier message: every row is new */
  func rebase(_ s: Snapshot) {
    index = [:]
    entries = []
    load(s)
    problem = nil
    epoch += 1
  }

  /** the user message that opened the turn `entry` belongs to */
  func prompt(before entry: Entry) -> Entry? {
    guard let i = index[entry.id] else { return nil }
    return entries[...i].last { $0.role == .user }
  }

  /** whether a user message comes after `entry`: going back to it would drop something */
  func hasTurn(after entry: Entry) -> Bool {
    guard let i = index[entry.id] else { return false }
    return entries[(i + 1)...].contains { $0.role == .user }
  }

  /** a message the phone shows at once; the host's copy has the same id and replaces it */
  func add(_ item: Item) {
    index[item.id] = entries.count
    entries.append(Entry(item))
  }

  func remove(_ id: String) {
    guard let i = index[id] else { return }
    entries.remove(at: i)
    reindex()
  }

  func apply(_ e: Event) {
    switch e.t {
    case "item":
      guard let item = e.item else { return }
      if let i = index[item.id], entries[i].role == item.role {
        if entries[i].item != item { entries[i].item = item }
      } else {
        add(item)
        entries.last?.arrived = .now
      }
    case "append":
      guard let id = e.id.flatMap(Self.string), let text = e.text, let i = index[id] else { return }
      entries[i].item.text += text
    case "state":
      let was = running
      running = e.running ?? false
      info.running = running
      if let error = e.error { problem = error }
      if was, !running { finished += 1 }
    case "info":
      if let t = e.title { info.title = t }
      if let u = e.updatedAt { info.updatedAt = u }
    case "config":
      if let c = e.config { config = c }
    case "usage":
      if let used = e.used, let size = e.size { usage = Usage(used: used, size: size) }
    case "permission":
      permission = e.permission
    default:
      break
    }
  }

  private func reindex() {
    index = [:]
    for (i, e) in entries.enumerated() { index[e.id] = i }
  }

  private static func string(_ j: JSON) -> String? {
    if case .string(let s) = j { s } else { nil }
  }
}
