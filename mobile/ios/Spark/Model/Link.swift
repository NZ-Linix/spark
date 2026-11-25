import Foundation
import Observation
import SwiftUI
import UIKit

private struct Problem: Decodable { var error: String }

struct LinkError: LocalizedError {
  let message: String
  var status = 0
  init(_ message: String, status: Int = 0) {
    self.message = message
    self.status = status
  }
  var errorDescription: String? { message }
}

/**
 * The line to the relay: one WebSocket that carries every host's messages. It reconnects on its own,
 * and when it does, the open session reloads so nothing said in the meantime is missed.
 */
@Observable
final class Link {
  enum Phase { case none, connecting, online, offline }

  /** the relay built into the app (SPARK_RELAY_URL in the build settings) */
  static let defaultRelay: URL = {
    #if DEBUG
      if let s = ProcessInfo.processInfo.environment["SPARK_RELAY"], let u = URL(string: s) { return u }
    #endif
    let s = Bundle.main.object(forInfoDictionaryKey: "SparkRelay") as? String ?? ""
    return URL(string: s.isEmpty ? "http://127.0.0.1:8799" : s)!
  }()

  private(set) var relay: URL? = UserDefaults.standard.url(forKey: "relay")
  /** paired a Mac or chose the cloud: past the first screen */
  private(set) var ready = UserDefaults.standard.bool(forKey: "ready") {
    didSet { UserDefaults.standard.set(ready, forKey: "ready") }
  }
  /** whether the relay runs cloud sessions, once known */
  private(set) var cloudAvailable = false
  private(set) var phase: Phase = .none
  private(set) var hosts: [HostEntry] = []
  var hostID: String? = UserDefaults.standard.string(forKey: "host") {
    didSet { UserDefaults.standard.set(hostID, forKey: "host") }
  }
  /** the host last picked by hand */
  private var wanted: String? = UserDefaults.standard.string(forKey: "wantedHost") ?? UserDefaults.standard.string(forKey: "host") {
    didSet { UserDefaults.standard.set(wanted, forKey: "wantedHost") }
  }
  var pickable: [HostEntry] { hosts }
  var sharedAccounts: Bool { hosts.contains { $0.kind == .cloud && $0.sharedAccounts == true } }
  private(set) var sessions: [String: [SessionInfo]] = [:]
  /** the options spark last offered on each host, so a new chat can pick a model before it exists */
  private(set) var mcpServers: [String: [String]] = [:]
  private(set) var configs = (try? JSONDecoder().decode([String: [ConfigOption]].self, from: UserDefaults.standard.data(forKey: "hostOptions") ?? Data())) ?? [:]
  private(set) var optionsRevision = 0
  var chat: Chat?

  @ObservationIgnored private var token: String? = Keychain.read("token")
  @ObservationIgnored private var socket: URLSessionWebSocketTask?
  @ObservationIgnored private var waiting: [String: CheckedContinuation<JSON, Error>] = [:]
  /** terminal commands waiting on output, by run id; see `Terminal` */
  @ObservationIgnored var terms: [String: (Event) -> Void] = [:]
  @ObservationIgnored private var next = 0
  @ObservationIgnored private var retry = 0
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var active = true
  /** chats on their way out, as host/id */
  @ObservationIgnored private var deleting: Set<String> = []

  var host: HostEntry? { hosts.first { $0.id == hostID } ?? hosts.first }
  var registered: Bool { relay != nil && token != nil }

  init() {
    #if DEBUG
      if let fixture = ProcessInfo.processInfo.environment["SPARK_SCROLL_FIXTURE"],
         let url = URL(string: fixture), url.host == "127.0.0.1" {
        relay = url
        token = "fixture"
        ready = true
        hostID = "cloud"
      }
    #endif
    if registered { connect() }
  }

  // MARK: Setup

  /**
   * Joins a relay: this iPhone gets its own token there, and with it the relay's cloud, if it has one.
   * A relay that only takes paired phones asks for the code from `spark pair`.
   */
  func join(_ address: String, code: String? = nil) async throws {
    let url = try Self.normalize(address)
    struct Joined: Decodable { var token: String; var hosts: [HostEntry] }
    var req = URLRequest(url: url.appending(path: "api/devices"))
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    var payload = ["name": UIDevice.current.name]
    if let code { payload["code"] = code }
    req.httpBody = try JSONEncoder().encode(payload)
    req.timeoutInterval = 15
    let joined: Joined = try await Self.fetch(req)
    disconnect()
    relay = url
    token = joined.token
    UserDefaults.standard.set(url, forKey: "relay")
    Keychain.write("token", joined.token)
    hosts = joined.hosts
    sessions = [:]
    clearOptions()
    connect()
  }

  /** Asks the relay what it offers, for the first screen. */
  func probe() async {
    struct Info: Decodable { var cloud: Bool }
    var req = URLRequest(url: (relay ?? Self.defaultRelay).appending(path: "api/info"))
    req.timeoutInterval = 8
    if let info: Info = try? await Self.fetch(req) { cloudAvailable = info.cloud }
  }

  /** First launch without a Mac: just the cloud. */
  func useCloud() async throws {
    if token == nil || relay == nil { try await join(Self.defaultRelay.absoluteString) }
    hostID = "cloud"
    ready = true
  }

  /** Pairs a Mac by the code `spark pair` shows. Joins the built-in relay first if this iPhone hasn't. */
  func pair(_ code: String) async throws -> HostEntry {
    // the Keychain outlives the app, so a token can be left from an install whose relay forgot it
    if token == nil || relay == nil { try await join(Self.defaultRelay.absoluteString, code: code) }
    do {
      return try await claim(code)
    } catch let e as LinkError where e.status == 401 {
      try await join((relay ?? Self.defaultRelay).absoluteString, code: code)
      return try await claim(code)
    }
  }

  private func claim(_ code: String) async throws -> HostEntry {
    guard let relay, let token else { throw LinkError("Couldn't reach the relay.") }
    struct Paired: Decodable { var host: HostEntry }
    var req = URLRequest(url: relay.appending(path: "api/pair"))
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.httpBody = try JSONEncoder().encode(["code": code])
    req.timeoutInterval = 15
    let paired: Paired = try await Self.fetch(req)
    if !hosts.contains(where: { $0.id == paired.host.id }) {
      hosts.insert(paired.host, at: 0)
    }
    choose(paired.host.id)
    return paired.host
  }

  /** after the pairing screen has shown its checkmark */
  func finishOnboarding() {
    ready = true
  }

  func unpair(_ host: HostEntry) async {
    guard let relay, let token else { return }
    var req = URLRequest(url: relay.appending(path: "api/hosts/\(host.id)"))
    req.httpMethod = "DELETE"
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    struct Left: Decodable { var hosts: [HostEntry] }
    if let left: Left = try? await Self.fetch(req) { hosts = left.hosts }
    configs[host.id] = nil
    saveOptions()
    if wanted == host.id { wanted = nil }
    if hostID == host.id { hostID = hosts.first?.id }
  }

  /** a host picked by hand */
  func choose(_ id: String) {
    wanted = id
    hostID = id
  }

  /** Keep the selected Mac visible even when it can't start a chat. */
  private func settleHost() {
    let open = pickable
    if let wanted, open.contains(where: { $0.id == wanted }) {
      if hostID != wanted { hostID = wanted }
    } else if !open.contains(where: { $0.id == hostID }) {
      hostID = open.first(where: \.online)?.id ?? open.first?.id
    }
  }

  func leave() {
    disconnect()
    relay = nil
    token = nil
    hosts = []
    sessions = [:]
    clearOptions()
    chat = nil
    UserDefaults.standard.removeObject(forKey: "relay")
    Keychain.write("token", nil)
    ready = false
    phase = .none
  }

  // MARK: Connection

  func setActive(_ on: Bool) {
    let resumed = on && !active
    active = on
    guard on, registered else { return }
    if resumed || (phase != .online && phase != .connecting) { connect() }
  }

  private func connect() {
    guard let relay, let token else { return }
    disconnect()
    generation += 1
    let gen = generation
    phase = .connecting
    var comps = URLComponents(url: relay.appending(path: "ws/device"), resolvingAgainstBaseURL: false)!
    comps.scheme = relay.scheme == "https" ? "wss" : "ws"
    var req = URLRequest(url: comps.url!)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let task = URLSession.shared.webSocketTask(with: req)
    task.maximumMessageSize = 16 * 1024 * 1024
    socket = task
    task.resume()
    Task { await receive(task, gen) }
    Task { await keepAlive(task, gen) }
  }

  private func disconnect() {
    socket?.cancel(with: .goingAway, reason: nil)
    socket = nil
    for (_, c) in waiting { c.resume(throwing: LinkError("The connection dropped.")) }
    waiting = [:]
  }

  private func receive(_ task: URLSessionWebSocketTask, _ gen: Int) async {
    var first = true
    while gen == generation {
      do {
        let message = try await task.receive()
        guard gen == generation, socket === task else { return }
        if first {
          first = false
          retry = 0
          phase = .online
          // not awaited here: its replies arrive through this same loop
          Task { await resync() }
        }
        let data: Data
        switch message {
        case .data(let d): data = d
        case .string(let s): data = Data(s.utf8)
        @unknown default: continue
        }
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data) else { continue }
        handle(env)
      } catch {
        guard gen == generation, socket === task else { return }
        dropped()
        return
      }
    }
  }

  private func keepAlive(_ task: URLSessionWebSocketTask, _ gen: Int) async {
    while gen == generation {
      try? await Task.sleep(for: .seconds(25))
      guard gen == generation else { return }
      task.sendPing { _ in }
    }
  }

  private func dropped() {
    disconnect()
    generation += 1
    phase = .offline
    guard active else { return }
    retry += 1
    let delay = min(10.0, 0.4 * pow(1.8, Double(retry)))
    let gen = generation
    Task {
      try? await Task.sleep(for: .seconds(delay))
      if gen == generation, active, phase == .offline { connect() }
    }
  }

  /** after a reconnect: the lists and the open session as they are now */
  private func resync() async {
    await refreshAll()
    if let chat { await reopen(chat) }
  }

  private func handle(_ env: Envelope) {
    if env.relay == "hosts", let hosts = env.hosts {
      let wasOnline = Set(self.hosts.filter(\.online).map(\.id))
      self.hosts = hosts
      settleHost()
      // a Mac that just came online has a list the sidebar hasn't seen
      for h in hosts where h.online && !wasOnline.contains(h.id) && phase == .online {
        Task { await refresh(h.id) }
      }
      return
    }
    if env.relay == "library-changed" {
      providersChanged()
      return
    }
    guard let host = env.host, let e = env.msg else { return }
    if e.t == "optionsChanged" {
      providersChanged()
      return
    }
    if e.t == "term", let run = e.run {
      terms[run]?(e)
      if e.done == true { terms[run] = nil }
      return
    }
    if e.t == "reply" {
      guard let n = e.id?.int, let c = waiting.removeValue(forKey: "\(host)#\(n)") else { return }
      if e.ok == true { c.resume(returning: e.result ?? .null) } else { c.resume(throwing: LinkError(e.error ?? "Something went wrong.")) }
      return
    }
    if let s = e.s, let chat, chat.host == host, chat.info.id == s { chat.apply(e) }
    if let s = e.s, var list = sessions[host], let i = list.firstIndex(where: { $0.id == s }) {
      switch e.t {
      case "state": list[i].running = e.running ?? false
      case "info":
        if let t = e.title { list[i].title = t }
        if let u = e.updatedAt { list[i].updatedAt = u }
      default: return
      }
      sessions[host] = list
    }
  }

  // MARK: Requests

  func request<T: Decodable>(_ host: String, _ op: String, _ fields: [String: JSON] = [:], as type: T.Type = JSON.self) async throws -> T {
    guard let socket, phase == .online else { throw LinkError(phase == .connecting ? "Still connecting to the relay." : "Not connected to the relay.") }
    next += 1
    let n = next
    var msg = fields
    msg["id"] = .number(Double(n))
    msg["op"] = .string(op)
    let data = try JSONEncoder().encode(["host": JSON.string(host), "msg": .object(msg)])
    let key = "\(host)#\(n)"
    let timeout = Task {
      do { try await Task.sleep(for: .seconds(op == "planAccount" ? 340 : op == "watchTerminal" ? 15 : op == "options" ? 40 : 90)) }
      catch { return }
      waiting.removeValue(forKey: key)?.resume(throwing: LinkError("The host took too long to answer."))
    }
    defer { timeout.cancel() }
    let result: JSON = try await withCheckedThrowingContinuation { c in
      waiting[key] = c
      socket.send(.string(String(decoding: data, as: UTF8.self))) { [weak self] error in
        guard let error else { return }
        Task { @MainActor in self?.waiting.removeValue(forKey: key)?.resume(throwing: error) }
      }
    }
    if T.self == JSON.self { return result as! T }
    return try result.decode(T.self)
  }

  // MARK: Sessions

  func refresh(_ host: String) async {
    guard var list = try? await request(host, "sessions", as: [SessionInfo].self) else { return }
    // a list asked for before a delete went through still has the chat: it stays gone
    list.removeAll { deleting.contains("\(host)/\($0.id)") }
    // an unchanged list leaves the sidebar alone, so a poll never redraws it
    if sessions[host] != list { sessions[host] = list }
  }

  /** every online host at once: the sidebar can show more than the chosen one */
  func refreshAll() async {
    guard phase == .online else { return }
    let online = hosts.filter(\.online).map(\.id)
    await withTaskGroup(of: Void.self) { group in
      for id in online { group.addTask { await self.refresh(id) } }
    }
  }

  /** the sessions of every host, each with the host it runs on */
  var listed: [Listed] {
    hosts.flatMap { h in (sessions[h.id] ?? []).map { Listed(host: h, session: $0) } }
  }

  func open(_ info: SessionInfo, on host: String) async {
    let chat = Chat(host: host, info: info)
    self.chat = chat
    await reopen(chat)
  }

  /**
   * A new chat whose first message shows at once. The session starts on the host behind it, takes
   * the options chosen before it existed, and then gets the message, with the same id as the one
   * already on screen so the host's copy replaces it in place.
   */
  @discardableResult
  func begin(_ text: String, in folder: String?, on host: String, options: [String: String], prompt: String?, mcpDisabled: Set<String> = []) -> Chat {
    let now = ISO8601DateFormatter().string(from: .now)
    // without a folder the host makes the chat one of its own; its path arrives with the session
    let chat = Chat(host: host, info: SessionInfo(id: "", title: Self.title(text), cwd: folder ?? "", updatedAt: now, live: true, running: true, origin: "phone", scratch: folder == nil))
    chat.loaded = true
    chat.starting = true
    chat.running = true
    let first = Item(id: UUID().uuidString, role: .user, text: text)
    chat.add(first)
    if let known = configs[host] { chat.config = known.map { o in var o = o; if let v = options[o.id] { o.currentValue = v }; return o } }
    self.chat = chat
    Task {
      do {
        var fields: [String: JSON] = [:]
        if let folder { fields["cwd"] = .string(folder) }
        if let prompt { fields["prompt"] = .string(prompt) }
        fields["mcpDisabled"] = .array(mcpDisabled.sorted().map(JSON.string))
        let snap = try await request(host, "new", fields, as: Snapshot.self)
        chat.adopt(snap)
        remember(chat)
        var list = sessions[host] ?? []
        list.insert(chat.info, at: 0)
        sessions[host] = list
        for id in ["provider", "model", "mode", "context", "effort"] {
          guard let value = options[id], let option = chat.config.first(where: { $0.id == id }), option.currentValue != value else { continue }
          // A provider change rebuilds the model options; the new provider may also have a different effort scale.
          if id == "effort", !option.options.contains(where: { $0.value == value }) { continue }
          chat.config = try await request(host, "config", ["s": .string(chat.info.id), "option": .string(id), "value": .string(value)], as: [ConfigOption].self)
        }
        remember(chat)
        _ = try await request(host, "prompt", ["s": .string(chat.info.id), "text": .string(text), "item": .string(first.id)])
        chat.problem = nil
      } catch {
        chat.starting = false
        chat.running = false
        chat.problem = error.localizedDescription
      }
    }
    return chat
  }

  /** what the sidebar calls a chat until spark names it */
  private static func title(_ text: String) -> String {
    let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    return line.count > 60 ? String(line.prefix(60)) + "…" : line
  }

  private func reopen(_ chat: Chat) async {
    do {
      let snap = try await request(chat.host, "open", ["s": .string(chat.info.id)], as: Snapshot.self)
      chat.load(snap)
      remember(chat)
      chat.problem = nil
    } catch {
      chat.problem = error.localizedDescription
      chat.loaded = true
    }
  }

  func follow(_ chat: Chat) async {
    while chat.elsewhere, !Task.isCancelled {
      try? await Task.sleep(for: chat.terminalOwner != nil ? .milliseconds(350) : .seconds(3))
      guard !Task.isCancelled, self.chat === chat, active, phase == .online else { continue }
      guard let revision = chat.terminalRevision else {
        await reopen(chat)
        continue
      }
      do {
        let snap = try await request(chat.host, "watchTerminal", ["s": .string(chat.info.id), "revision": .string(revision)], as: Snapshot?.self)
        guard !Task.isCancelled, chat.terminalRevision == revision, let snap else { continue }
        chat.load(snap)
        remember(chat)
      } catch {
        guard !Task.isCancelled else { return }
        // An older bridge or a dropped connection can be recovered by a normal open.
        await reopen(chat)
      }
    }
  }

  @discardableResult
  func send(_ text: String, in chat: Chat) async -> Bool {
    guard chat.canSend else { return false }
    chat.sending = true
    defer { chat.sending = false }
    let item = Item(id: UUID().uuidString, role: .user, text: text)
    let owner = chat.terminalOwner
    var fields: [String: JSON] = ["s": .string(chat.info.id), "text": .string(text), "item": .string(item.id)]
    if let owner {
      fields["terminalOwner"] = .string(owner)
    } else {
      chat.add(item)
      chat.running = true
    }
    do {
      _ = try await request(chat.host, "prompt", fields)
      chat.problem = nil
      return true
    } catch {
      if owner == nil {
        chat.remove(item.id)
        chat.running = false
      }
      chat.problem = error.localizedDescription
      return false
    }
  }

  /**
   * Takes the chat back to `entry`. Without `keep`, to just before it, and returns its text for the
   * composer; with `keep`, to just after the reply it ends. The host forks the session at that point
   * and drops the old one, so the chat carries on under the fork's id.
   */
  @discardableResult
  func rewind(_ chat: Chat, to entry: Entry, keep: Bool) async throws -> String? {
    let old = chat.info.id
    chat.rewinding = true
    defer { chat.rewinding = false }
    let snap = try await request(chat.host, "rewind", ["s": .string(old), "item": .string(entry.id), "keep": .bool(keep)], as: Snapshot.self)
    var t = Transaction()
    t.disablesAnimations = true
    withTransaction(t) { chat.rebase(snap) }
    remember(chat)
    if var list = sessions[chat.host] {
      list.removeAll { $0.id == old || $0.id == chat.info.id }
      list.insert(chat.info, at: 0)
      sessions[chat.host] = list
    }
    return snap.restored
  }

  /** the library prompt a chat runs with from its next message; empty for spark's own */
  func setPrompt(_ chat: Chat, to name: String) async {
    let before = chat.prompt
    chat.prompt = name
    do {
      let snap = try await request(chat.host, "sessionPrompt", ["s": .string(chat.info.id), "prompt": name.isEmpty ? .null : .string(name)], as: Snapshot.self)
      chat.load(snap)
      remember(chat)
      chat.problem = nil
    } catch {
      chat.prompt = before
      chat.problem = error.localizedDescription
    }
  }

  func cancel(_ chat: Chat) async {
    guard !chat.info.id.isEmpty else { return }
    var fields: [String: JSON] = ["s": .string(chat.info.id)]
    if let owner = chat.terminalOwner { fields["terminalOwner"] = .string(owner) }
    do {
      _ = try await request(chat.host, "cancel", fields)
    } catch {
      chat.problem = error.localizedDescription
    }
  }

  func rename(_ session: SessionInfo, on host: String, to title: String) async throws {
    _ = try await request(host, "sessionRename", ["s": .string(session.id), "title": .string(title)])
    if var list = sessions[host], let i = list.firstIndex(where: { $0.id == session.id }) {
      list[i].title = title
      sessions[host] = list
    }
    if let chat, chat.host == host, chat.info.id == session.id { chat.info.title = title }
  }

  /** the chat leaves the list at once; it comes back if the host couldn't delete it */
  func delete(_ session: SessionInfo, on host: String) async throws {
    let key = "\(host)/\(session.id)"
    let before = sessions[host]
    deleting.insert(key)
    defer { deleting.remove(key) }
    sessions[host]?.removeAll { $0.id == session.id }
    if let chat, chat.host == host, chat.info.id == session.id { self.chat = nil }
    do {
      _ = try await request(host, "sessionDelete", ["s": .string(session.id)])
    } catch {
      if let before, sessions[host]?.contains(where: { $0.id == session.id }) == false { sessions[host] = before }
      throw error
    }
  }

  func answer(_ chat: Chat, _ p: Permission, option: String?) async {
    chat.permission = nil
    _ = try? await request(chat.host, "answer", ["s": .string(chat.info.id), "request": .string(p.id), "option": option.map(JSON.string) ?? .null])
  }

  func set(_ chat: Chat, _ option: String, to value: String) async {
    let previous = chat.config.first(where: { $0.id == option })?.currentValue
    if let i = chat.config.firstIndex(where: { $0.id == option }) { chat.config[i].currentValue = value }
    do {
      chat.config = try await request(chat.host, "config", ["s": .string(chat.info.id), "option": .string(option), "value": .string(value)], as: [ConfigOption].self)
      remember(chat)
    } catch {
      if let previous, let i = chat.config.firstIndex(where: { $0.id == option && $0.currentValue == value }) {
        chat.config[i].currentValue = previous
      }
      chat.problem = error.localizedDescription
    }
  }

  private func remember(_ chat: Chat) {
    if !chat.config.isEmpty { configs[chat.host] = chat.config }
  }

  /** what a new chat on this host starts with, when no chat there has told us yet */
  func loadMcpServers(_ host: String) async {
    if let names = try? await request(host, "mcpServers", as: [String].self) { mcpServers[host] = names }
  }

  func setMcp(_ chat: Chat, disabled: Set<String>) async {
    guard !chat.changingMcp, !chat.running, !chat.elsewhere else { return }
    chat.changingMcp = true
    let before = chat.mcpDisabled
    chat.mcpDisabled = disabled
    defer { chat.changingMcp = false }
    do {
      let saved = try await request(chat.host, "sessionMcp", ["s": .string(chat.info.id), "disabled": .array(disabled.sorted().map(JSON.string))], as: [String].self)
      chat.mcpDisabled = Set(saved)
    } catch {
      chat.mcpDisabled = before
      chat.problem = error.localizedDescription
    }
  }

  @discardableResult
  func loadOptions(_ host: String, provider: String? = nil) async throws -> [ConfigOption] {
    let fields: [String: JSON] = provider.map { ["provider": .string($0)] } ?? [:]
    let options = try await request(host, "options", fields, as: [ConfigOption].self)
    try Task.checkCancellation()
    guard options.contains(where: { $0.id == "model" }) else { throw LinkError("This host didn't offer any models.") }
    if let provider {
      guard options.contains(where: { $0.id == "provider" && $0.currentValue == provider }) else { throw LinkError("This provider isn't available on the host.") }
    } else {
      configs[host] = options
      saveOptions()
    }
    return options
  }

  private func saveOptions() {
    if let data = try? JSONEncoder().encode(configs) { UserDefaults.standard.set(data, forKey: "hostOptions") }
  }

  private func clearOptions() {
    configs = [:]
    UserDefaults.standard.removeObject(forKey: "hostOptions")
  }

  // MARK: Providers and prompts

  private func providersChanged() {
    optionsRevision += 1
  }

  func providers(_ host: String = "cloud") async throws -> [ProviderSummary] {
    try await request(host, "providers", as: [ProviderSummary].self)
  }

  /** the subscription accounts of `plan` on a paired Mac */
  func planAccounts(_ host: String, plan: SubscriptionPlan) async throws -> [ProviderSummary] {
    try await request(host, "planAccounts", ["plan": .string(plan.rawValue)], as: [ProviderSummary].self)
  }

  struct PlanAccountUpdate: Decodable {
    let accounts: [ProviderSummary]
    let warning: String?
  }

  /** signs in to (`connect`, `reconnect`) or removes an account; sign-in opens in the Mac's browser */
  func changePlanAccount(_ host: String, plan: SubscriptionPlan, action: String, value: String) async throws -> PlanAccountUpdate {
    let result = try await request(host, "planAccount", ["plan": .string(plan.rawValue), "action": .string(action), "value": .string(value)], as: PlanAccountUpdate.self)
    providersChanged()
    return result
  }

  /** the shared prompts; the cloud keeps them */
  private(set) var prompts: [PromptSummary] = []

  @discardableResult
  func loadPrompts() async throws -> [PromptSummary] {
    prompts = try await request("cloud", "prompts", as: [PromptSummary].self)
    return prompts
  }

  @discardableResult
  func putPrompt(_ name: String, text: String, previous: String? = nil) async throws -> [PromptSummary] {
    var fields: [String: JSON] = ["name": .string(name), "text": .string(text)]
    if let previous, previous != name { fields["previous"] = .string(previous) }
    prompts = try await request("cloud", "promptPut", fields, as: [PromptSummary].self)
    return prompts
  }

  @discardableResult
  func deletePrompt(_ name: String) async throws -> [PromptSummary] {
    prompts = try await request("cloud", "promptDelete", ["name": .string(name)], as: [PromptSummary].self)
    return prompts
  }

  /** the shared MCP servers; the cloud keeps them and every paired Mac gets a copy */
  private(set) var mcpLibrary: [McpSummary] = []

  @discardableResult
  func loadMcpLibrary() async throws -> [McpSummary] {
    mcpLibrary = try await request("cloud", "mcpList", as: [McpSummary].self)
    return mcpLibrary
  }

  /** `previous` renames one; a null env or header value keeps the saved one */
  func putMcp(_ name: String, _ server: [String: JSON], previous: String? = nil) async throws {
    var fields: [String: JSON] = ["name": .string(name), "server": .object(server)]
    if let previous, previous != name { fields["previous"] = .string(previous) }
    mcpLibrary = try await request("cloud", "mcpPut", fields, as: [McpSummary].self)
    mcpChanged()
  }

  func deleteMcp(_ name: String) async throws {
    mcpLibrary = try await request("cloud", "mcpDelete", ["name": .string(name)], as: [McpSummary].self)
    mcpChanged()
  }

  func setMcpEnabled(_ name: String, _ enabled: Bool) async throws {
    mcpLibrary = try await request("cloud", "mcpEnabled", ["name": .string(name), "enabled": .bool(enabled)], as: [McpSummary].self)
    mcpChanged()
  }

  /** each host lists the servers a chat can turn off; a Mac gets its copy a moment after the cloud */
  private func mcpChanged() {
    let online = hosts.filter(\.online).map(\.id)
    Task {
      await loadMcpServers("cloud")
      try? await Task.sleep(for: .seconds(2))
      for host in online where host != "cloud" { await loadMcpServers(host) }
    }
  }

  /** writes a provider into a host's profile; spark checks it first. `previous` renames one. */
  func putProvider(_ name: String, _ provider: [String: JSON], model: String?, env: [String: JSON] = [:], previous: String? = nil, on host: String = "cloud") async throws -> [ProviderSummary] {
    var fields: [String: JSON] = ["name": .string(name), "provider": .object(provider)]
    if let model, !model.isEmpty { fields["model"] = .string(model) }
    if !env.isEmpty { fields["env"] = .object(env) }
    if let previous, previous != name { fields["previous"] = .string(previous) }
    let list = try await request(host, "providerPut", fields, as: [ProviderSummary].self)
    // a new chat asks the host again, so it sees the new models
    providersChanged()
    return list
  }

  func deleteProvider(_ name: String, on host: String = "cloud") async throws -> [ProviderSummary] {
    let list = try await request(host, "providerDelete", ["name": .string(name)], as: [ProviderSummary].self)
    providersChanged()
    return list
  }

  func folders(_ host: String, _ path: String?) async throws -> Listing {
    try await request(host, "folders", path.map { ["path": .string($0)] } ?? [:], as: Listing.self)
  }

  func search(_ host: String, _ query: String, in path: String?) async throws -> [Folder] {
    var fields: [String: JSON] = ["query": .string(query)]
    if let path { fields["path"] = .string(path) }
    return try await request(host, "search", fields, as: [Folder].self)
  }

  func mkdir(_ host: String, in path: String, named name: String) async throws -> String {
    try await request(host, "mkdir", ["path": .string(path), "name": .string(name)], as: String.self)
  }

  /** returns the folder's new path */
  func renameFolder(_ host: String, _ path: String, to name: String) async throws -> String {
    try await request(host, "folderRename", ["path": .string(path), "name": .string(name)], as: String.self)
  }

  func deleteFolder(_ host: String, _ path: String) async throws {
    _ = try await request(host, "folderDelete", ["path": .string(path)])
  }

  // MARK: HTTP

  private static func normalize(_ address: String) throws -> URL {
    var s = address.trimmingCharacters(in: .whitespacesAndNewlines)
    while s.hasSuffix("/") { s.removeLast() }
    if !s.contains("://") {
      // a bare address on the local network is a dev relay without TLS
      let local = s.hasPrefix("localhost") || s.hasPrefix("127.") || s.hasPrefix("192.168.") || s.hasPrefix("10.") || s.contains(".local")
      s = (local ? "http://" : "https://") + s
    }
    guard let url = URL(string: s), url.host() != nil else { throw LinkError("That doesn't look like an address.") }
    return url
  }

  private static func fetch<T: Decodable>(_ req: URLRequest) async throws -> T {
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await URLSession.shared.data(for: req)
    } catch {
      throw LinkError("Couldn't reach the relay.")
    }
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      throw LinkError((try? JSONDecoder().decode(Problem.self, from: data))?.error ?? "The relay answered \(status).", status: status)
    }
    return try JSONDecoder().decode(T.self, from: data)
  }
}
