import Foundation
import Observation
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
  private(set) var sessions: [String: [SessionInfo]] = [:]
  private(set) var loadingSessions = false
  /** the options spark last offered on each host, so a new chat can pick a model before it exists */
  private(set) var configs: [String: [ConfigOption]] = [:]
  var chat: Chat?

  @ObservationIgnored private var token: String? = Keychain.read("token")
  @ObservationIgnored private var socket: URLSessionWebSocketTask?
  @ObservationIgnored private var waiting: [String: CheckedContinuation<JSON, Error>] = [:]
  @ObservationIgnored private var next = 0
  @ObservationIgnored private var retry = 0
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var active = true

  var host: HostEntry? { hosts.first { $0.id == hostID } ?? hosts.first }
  var registered: Bool { relay != nil && token != nil }

  init() {
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
    hostID = paired.host.id
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
    if hostID == host.id { hostID = hosts.first?.id }
  }

  func leave() {
    disconnect()
    relay = nil
    token = nil
    hosts = []
    sessions = [:]
    chat = nil
    UserDefaults.standard.removeObject(forKey: "relay")
    Keychain.write("token", nil)
    ready = false
    phase = .none
  }

  // MARK: Connection

  func setActive(_ on: Bool) {
    active = on
    if on, registered, phase != .online, phase != .connecting { connect() }
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
        guard gen == generation else { return }
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
    socket = nil
    for (_, c) in waiting { c.resume(throwing: LinkError("The connection dropped.")) }
    waiting = [:]
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
      if hostID == nil || !hosts.contains(where: { $0.id == hostID }) { hostID = hosts.first?.id }
      // a Mac that just came online has a list the sidebar hasn't seen
      for h in hosts where h.online && !wasOnline.contains(h.id) && phase == .online {
        Task { await refresh(h.id) }
      }
      return
    }
    guard let host = env.host, let e = env.msg else { return }
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
    let result: JSON = try await withCheckedThrowingContinuation { c in
      waiting[key] = c
      socket.send(.string(String(decoding: data, as: UTF8.self))) { [weak self] error in
        guard let error else { return }
        Task { @MainActor in self?.waiting.removeValue(forKey: key)?.resume(throwing: error) }
      }
      Task {
        try? await Task.sleep(for: .seconds(90))
        self.waiting.removeValue(forKey: key)?.resume(throwing: LinkError("The host took too long to answer."))
      }
    }
    if T.self == JSON.self { return result as! T }
    return try result.decode(T.self)
  }

  // MARK: Sessions

  func refresh(_ host: String) async {
    loadingSessions = true
    defer { loadingSessions = false }
    if let list = try? await request(host, "sessions", as: [SessionInfo].self) { sessions[host] = list }
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

  func start(in folder: String, on host: String) async throws -> Chat {
    let snap = try await request(host, "new", ["cwd": .string(folder)], as: Snapshot.self)
    let chat = Chat(host: host, info: snap.info)
    chat.load(snap)
    remember(chat)
    self.chat = chat
    var list = sessions[host] ?? []
    list.insert(snap.info, at: 0)
    sessions[host] = list
    return chat
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

  func send(_ text: String, in chat: Chat) async {
    do {
      _ = try await request(chat.host, "prompt", ["s": .string(chat.info.id), "text": .string(text)])
      chat.problem = nil
    } catch {
      chat.problem = error.localizedDescription
    }
  }

  func cancel(_ chat: Chat) async {
    _ = try? await request(chat.host, "cancel", ["s": .string(chat.info.id)])
  }

  func answer(_ chat: Chat, _ p: Permission, option: String?) async {
    chat.permission = nil
    _ = try? await request(chat.host, "answer", ["s": .string(chat.info.id), "request": .string(p.id), "option": option.map(JSON.string) ?? .null])
  }

  func set(_ chat: Chat, _ option: String, to value: String) async {
    if let i = chat.config.firstIndex(where: { $0.id == option }) { chat.config[i].currentValue = value }
    do {
      chat.config = try await request(chat.host, "config", ["s": .string(chat.info.id), "option": .string(option), "value": .string(value)], as: [ConfigOption].self)
      remember(chat)
    } catch {
      chat.problem = error.localizedDescription
    }
  }

  private func remember(_ chat: Chat) {
    if !chat.config.isEmpty { configs[chat.host] = chat.config }
  }

  /** what a new chat on this host starts with, when no chat there has told us yet */
  func loadOptions(_ host: String) async {
    guard configs[host] == nil else { return }
    if let options = try? await request(host, "options", [:], as: [ConfigOption].self), !options.isEmpty {
      configs[host] = options
    }
  }

  // MARK: Providers

  func providers(_ host: String) async throws -> [ProviderSummary] {
    try await request(host, "providers", as: [ProviderSummary].self)
  }

  /** writes a provider into the cloud's profile; spark checks it first */
  func putProvider(_ name: String, _ provider: [String: JSON], model: String?, env: [String: JSON] = [:]) async throws -> [ProviderSummary] {
    var fields: [String: JSON] = ["name": .string(name), "provider": .object(provider)]
    if let model, !model.isEmpty { fields["model"] = .string(model) }
    if !env.isEmpty { fields["env"] = .object(env) }
    let list = try await request("cloud", "providerPut", fields, as: [ProviderSummary].self)
    // a new chat asks the cloud again, so it sees the new models
    configs["cloud"] = nil
    return list
  }

  func deleteProvider(_ name: String) async throws -> [ProviderSummary] {
    let list = try await request("cloud", "providerDelete", ["name": .string(name)], as: [ProviderSummary].self)
    configs["cloud"] = nil
    return list
  }

  /** a one-time copy: later changes on either side stay on that side */
  func copyProvider(_ name: String, from mac: String, as newName: String) async throws -> [ProviderSummary] {
    struct Export: Decodable { var provider: [String: JSON]; var model: String?; var env: [String: JSON] }
    let e = try await request(mac, "providerExport", ["name": .string(name)], as: Export.self)
    return try await putProvider(newName, e.provider, model: e.model, env: e.env)
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
