import Foundation
import Observation

/** One open session: its messages as they stream in, whether spark is working, and what it's asking. */
@Observable
final class Chat {
  let host: String
  var info: SessionInfo
  var items: [Item] = []
  var running = false
  var config: [ConfigOption] = []
  var permission: Permission?
  var usage: Usage?
  var loaded = false
  var problem: String?
  /** bumped when a reply finishes, for the haptic */
  var finished = 0

  @ObservationIgnored private var index: [String: Int] = [:]

  init(host: String, info: SessionInfo) {
    self.host = host
    self.info = info
    self.running = info.running
  }

  var key: String { "\(host)/\(info.id)" }

  func load(_ s: Snapshot) {
    info = s.info
    items = s.items
    running = s.running
    config = s.config
    permission = s.permission
    usage = s.usage
    reindex()
    loaded = true
  }

  func apply(_ e: Event) {
    switch e.t {
    case "item":
      guard let item = e.item else { return }
      if let i = index[item.id] {
        items[i] = item
      } else {
        index[item.id] = items.count
        items.append(item)
      }
    case "append":
      guard let id = e.id.flatMap(Self.string), let text = e.text, let i = index[id] else { return }
      items[i].text += text
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
    for (i, item) in items.enumerated() { index[item.id] = i }
  }

  private static func string(_ j: JSON) -> String? {
    if case .string(let s) = j { s } else { nil }
  }
}
