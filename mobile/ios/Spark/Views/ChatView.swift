import SwiftUI

/** One session as a conversation: your messages in bubbles, spark's answers and work beneath them. */
struct ChatView: View {
  @Environment(Link.self) private var link
  @Environment(\.shell) private var shell
  let chat: Chat
  private var draft: String {
    get { link.draft(for: chat) }
    nonmutating set { link.setDraft(newValue, for: chat) }
  }
  @FocusState private var focused: Bool
  @State private var sent = 0
  /** following the newest text: on at the bottom, off once you scroll up, on again back down */
  @State private var pinned = true
  /** a finger is on the thread, or it's still gliding from one */
  @State private var scrolling = false
  /** far enough up that a button back down helps */
  @State private var away = false
  /** carries the thread to its newest text, and keeps carrying it while a reply streams in */
  @State private var follower = Follower()
  /** the thread has been laid out at its newest text, so the anchor that put it there can let go */
  @State private var settled = false
  /** an edit has its own text; it never replaces the unsent draft */
  @State private var editing: MessageEdit?
  @State private var historyAction: HistoryAction?
  /** covers the entire rewind and replacement send, including the handoff between them */
  @State private var historyBusy = false
  @State private var browsing = false
  /** kept while the chat is open, so a command keeps running with the terminal closed */
  @State private var terminal: Terminal?
  /** the terminal on screen; set by item so the sheet never opens before it exists */
  @State private var typing: Terminal?

  var body: some View {
    ZStack {
      if chat.loaded {
        // the thread stays mounted from the start, so the first message lands in it instead of swapping screens
        thread
        if chat.isEmpty, !chat.running {
          Fresh(folder: chat.info.folder, host: link.hosts.first { $0.id == chat.host })
            .allowsHitTesting(false)
            .transition(.opacity)
        }
      } else {
        ProgressView().tint(Color.dim).transition(.opacity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .page()
    .safeAreaInset(edge: .bottom, spacing: 0) { bottom }
    .navigationBarTitleDisplayMode(.inline)
    .toolbar { toolbar }
    .sheet(isPresented: $browsing) { FilesView(host: chat.host, root: chat.info.cwd) }
    .sheet(item: $typing) { TerminalView(terminal: $0) }
    .confirmationDialog(historyAction?.title ?? "Change chat history?",
      isPresented: Binding(get: { historyAction != nil }, set: { if !$0 { historyAction = nil } }),
      titleVisibility: .visible, presenting: historyAction
    ) { action in
      Button(action.button, role: .destructive) { perform(action) }
    } message: { action in
      Text(action.message)
    }
    .sensoryFeedback(.impact(weight: .light), trigger: sent)
    .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.6), trigger: chat.finished)
    .sensoryFeedback(.impact(weight: .medium), trigger: chat.epoch)
    .sensoryFeedback(trigger: chat.permission?.id) { _, new in new == nil ? nil : .warning }
    .onAppear { if chat.loaded, chat.isEmpty, !chat.running { focused = true } }
    .onChange(of: chat.loaded) { _, loaded in if loaded, chat.isEmpty { focused = true } }
    .task(id: chat.elsewhere) { if chat.elsewhere { await link.follow(chat) } }
    .task(id: link.phase == .online) {
      if link.phase == .online { await link.loadMcpServers(chat.host) }
      // the chat's prompt can change from the model sheet once the library's prompts are known
      guard link.phase == .online, link.prompts.isEmpty, link.hosts.contains(where: { $0.kind == .cloud }) else { return }
      _ = try? await link.loadPrompts()
    }
  }

  private var bottom: some View {
    VStack(spacing: 10) {
      if let p = chat.permission {
        PermissionCard(permission: p) { option in
          Task { await link.answer(chat, p, option: option) }
        }
        .padding(.horizontal, 10)
        .transition(Settle(distance: 24))
      }
      if let problem = chat.problem ?? elsewhereNote {
        Text(problem)
          .font(.geist(13))
          .foregroundStyle(Color.dim)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 24)
          .transition(.opacity)
      }
      if !chat.queue.isEmpty {
        QueuePanel(chat: chat, remove: { link.removeQueued($0, in: chat) }, resume: { link.resumeQueue(chat) })
          .padding(.horizontal, 10)
          .transition(Settle(distance: 16))
      }
      if let editing {
        EditingBar(replacement: editing.target == nil) {
          withAnimation(.smooth(duration: 0.3)) { self.editing = nil }
        }
          .disabled(historyBusy)
          .padding(.horizontal, 14)
          .transition(Settle(distance: 12))
      }
      Composer(
        text: composerText, focused: $focused, running: chat.running && (!chat.elsewhere || chat.terminalOwner != nil),
        enabled: chat.loaded && (!chat.elsewhere || chat.terminalOwner != nil) && !chat.rewinding && !historyBusy && link.phase == .online,
        placeholder: editing == nil ? "Message spark" : "Edit your message",
        working: chat.terminalOwner != nil ? "Message the Mac…" : "Queue a follow-up…",
        canSendWhileRunning: chat.terminalOwner != nil,
        queuesMessages: editing == nil && chat.terminalOwner == nil,
        actionEnabled: editing == nil ? chat.canSend || chat.canQueue : changeable,
        stopEnabled: !chat.stopping
      ) {
        if editing != nil { sendEdit() } else { send() }
      } stop: {
        Task { await link.cancel(chat) }
      } trailing: {
        ConfigChips(host: chat.host, options: chat.config, set: { id, value in
          if id == "effort" { UserDefaults.standard.set(value, forKey: "effort") }
          Task { await link.set(chat, id, to: value) }
        }, chooseModel: { choice in Task { await link.setModel(chat, to: choice) } },
          prompts: link.prompts, prompt: promptBinding, mcpNames: link.mcpServers[chat.host] ?? [],
          mcpDisabled: Binding(get: { chat.mcpDisabled }, set: { disabled in Task { await link.setMcp(chat, disabled: disabled) } }),
          mcpEditable: !chat.running && !chat.changingMcp, refreshMcp: { await link.loadMcpServers(chat.host) },
          compact: true, modelsEditable: changeable && !chat.sending)
          .disabled(chat.changingModel)
      }
    }
    .animation(.spring(duration: 0.35, bounce: 0.1), value: chat.queue.map(\.id))
    .animation(.spring(duration: 0.35, bounce: 0.1), value: editing != nil)
    .readable()
  }

  private var composerText: Binding<String> {
    if editing != nil {
      return Binding(get: { editing?.text ?? "" }, set: { editing?.text = $0 })
    }
    return Binding(get: { draft }, set: { draft = $0 })
  }

  /** the chat's library prompt; a change starts its spark again with the new one */
  private var promptBinding: Binding<String> {
    Binding(get: { chat.prompt }, set: { name in
      guard name != chat.prompt else { return }
      Task { await link.setPrompt(chat, to: name) }
    })
  }

  /** why the composer is off while another spark process has the chat open */
  private var elsewhereNote: String? {
    guard chat.elsewhere, chat.terminalOwner == nil else { return nil }
    let name = link.hosts.first { $0.id == chat.host }?.name ?? "the Mac"
    return "Open in spark on \(name). Close it there to write here."
  }

  /** what a row's menu can do now: nothing changes the chat while spark works on it */
  private var changeable: Bool {
    chat.loaded && !historyBusy && !chat.running && !chat.sending && !chat.elsewhere && !chat.starting &&
      !chat.rewinding && !chat.changingMcp && !chat.changingModel && !chat.info.id.isEmpty && link.phase == .online
  }

  private var thread: some View {
    let units = Unit.build(chat.entries)
    let liveID = chat.running ? chat.entries.last?.id : nil
    let first = chat.starting ? chat.entries.first?.id : nil
    let ends = turnEnds
    let target = editing?.target?.id
    // The edited message stays readable; the rows that a replacement removes fade behind it.
    let cut = target.flatMap { id in chat.entries.firstIndex { $0.id == id } }
    let after = cut.map { Set(chat.entries.dropFirst($0 + 1).map(\.id)) } ?? []
    let editableRows = changeable && editing == nil
    return ScrollViewReader { reader in
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(units) { unit in
            Group {
              switch unit.kind {
              case .one(let entry):
                Row(entry: entry, live: entry.id == liveID, arriving: entry.id == first, ends: ends.contains(entry.id),
                    changeable: editableRows, canRewind: editableRows && ends.contains(entry.id) && chat.hasTurn(after: entry),
                    editing: entry.id == target, disclose: pauseFollowing, act: act)
              case .tools(let entries):
                ToolGroup(entries: entries, live: entries.last?.id == liveID, disclose: pauseFollowing)
              }
            }
            .padding(.top, unit.gap)
            .opacity(after.contains(unit.id) ? 0.35 : 1)
          }
          if chat.running {
            WorkingLine(chat: chat)
          }
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 24)
        .readable()
        Color.clear.frame(height: 1).id("chat-bottom").accessibilityHidden(true)
          .background(ScrollFinder(found: { follower.scrollView = $0 }, tap: focused ? { focused = false } : nil))
      }
      // going back to an earlier message lays the thread out afresh, from the bottom
      .id(chat.epoch)
      .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 12)), removal: .opacity))
      // opens on the newest text; once laid out the anchor lets go, since while it holds, the bottom
      // edge sticks and growing text jumps the thread a line at a time instead of the follower gliding
      .defaultScrollAnchor(settled ? nil : .bottom, for: .initialOffset)
      // a short chat reads from the top, so a new one starts under the title and grows down
      .defaultScrollAnchor(.top, for: .alignment)
      .scrollDismissesKeyboard(.interactively)
      .onScrollPhaseChange { _, phase in
        scrolling = phase == .tracking || phase == .interacting || phase == .decelerating
        // a finger on the thread takes it from the follower
        if phase == .tracking || phase == .interacting { follower.stop() }
      }
      .onScrollGeometryChange(for: Fill.self, of: Fill.init) { old, new in
        if scrolling, new.offset != old.offset { pinned = new.distance < 44 }
        if away != (new.distance > 160) { away = new.distance > 160 }
        if pinned, !scrolling, new.end != old.end, new.distance > 1 { follower.glide() }
      }
      .onChange(of: chat.epoch) { _, _ in
        settled = false
        follow(reader)
      }
      .task(id: "\(chat.epoch)-\(chat.loaded)") {
        guard chat.loaded, !settled else { return }
        try? await Task.sleep(for: .milliseconds(400))
        settled = true
      }
      .onChange(of: sent) { _, _ in follower.glide() }
      .overlay(alignment: .bottom) {
        if away && !pinned {
          Button {
            // a tap while the thread still glides takes over from the glide
            scrolling = false
            pinned = true
            follower.glide()
          } label: {
            Image(systemName: "arrow.down")
              .font(.system(size: 14, weight: .semibold))
              .frame(width: 38, height: 38)
              .glassEffect(.regular.interactive(), in: .circle)
              .contentShape(.circle)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Scroll to the newest")
          .padding(.bottom, 12)
          .transition(.scale(0.8).combined(with: .opacity))
        }
      }
      .overlay {
        if historyBusy || chat.rewinding {
          ProgressView().tint(Color.dim)
            .accessibilityLabel("Updating chat history")
            .allowsHitTesting(false)
            .transition(.opacity)
        }
      }
      .animation(.smooth(duration: 0.2), value: historyBusy || chat.rewinding)
      // the rows an edit would replace fade together, and come back together when it's dropped
      .animation(.smooth(duration: 0.3), value: editing?.target?.id)
      .animation(.smooth(duration: 0.35), value: chat.epoch)
    }
  }

  /** the last answer in each turn, which gets the copy, retry and go-back buttons */
  private var turnEnds: Set<String> {
    var ends = Set<String>()
    var last: String?
    for e in chat.entries {
      if e.role == .user {
        if let last { ends.insert(last) }
        last = nil
      } else if e.role == .assistant {
        last = e.id
      }
    }
    if let last, !chat.running { ends.insert(last) }
    return ends
  }

  /** the newest text at once, for a thread laid out afresh */
  private func follow(_ reader: ScrollViewProxy) {
    follower.stop()
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) { reader.scrollTo("chat-bottom", anchor: .bottom) }
  }

  private func pauseFollowing() {
    pinned = false
    follower.stop()
  }

  @ToolbarContentBuilder private var toolbar: some ToolbarContent {
    ToolbarItem(placement: .topBarLeading) {
      Button("Chats", systemImage: shell.menuSymbol) { shell.menu() }
    }
    ToolbarItem(placement: .principal) {
      Text(chat.info.title)
        .font(.geist(15, .semibold))
        .lineLimit(1)
        .contentTransition(.opacity)
        .frame(maxWidth: 240)
        .animation(.ease, value: chat.info.title)
    }
    // a chat without a folder learns its own once the host has made it
    if !chat.info.cwd.isEmpty {
      ToolbarItemGroup(placement: .topBarTrailing) {
        Button("Files", systemImage: "folder") {
          focused = false
          browsing = true
        }
        Button("Terminal", systemImage: "apple.terminal") {
          focused = false
          if terminal?.host != chat.host || terminal?.root != chat.info.cwd {
            terminal = Terminal(host: chat.host, root: chat.info.cwd)
          }
          typing = terminal
        }
      }
    }
  }

  private func act(_ action: RowAction, _ entry: Entry) {
    switch action {
    case .copy:
      UIPasteboard.general.string = entry.item.text
    case .edit:
      guard changeable, editing == nil else { return }
      withAnimation(.smooth(duration: 0.3)) { editing = MessageEdit(target: entry, text: entry.item.text) }
      focused = true
    case .retry:
      guard changeable, editing == nil, let prompt = entry.role == .user ? entry : chat.prompt(before: entry) else { return }
      if chat.hasTurn(after: prompt) {
        historyAction = .retry(prompt)
      } else {
        perform(.retry(prompt))
      }
    case .rewind:
      guard changeable, editing == nil, chat.hasTurn(after: entry) else { return }
      historyAction = .rewind(entry)
    }
  }

  private func perform(_ action: HistoryAction) {
    historyAction = nil
    guard changeable, editing == nil else { return }
    switch action {
    case .rewind(let reply):
      guard chat.hasTurn(after: reply) else { return }
      updateHistory(to: reply)
    case .retry(let prompt):
      guard chat.entries.contains(where: { $0.id == prompt.id }) else { return }
      updateHistory(to: prompt, replacement: prompt.item.text)
    }
  }

  private func sendEdit() {
    guard changeable, let editing else { return }
    let text = editing.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    updateHistory(to: editing.target, replacement: text)
  }

  /** Rewind before a replacement, or keep the requested reply. A failed send can use the fork as-is. */
  private func updateHistory(to target: Entry?, replacement: String? = nil) {
    historyBusy = true
    focused = false
    chat.problem = nil
    Task {
      defer { historyBusy = false }
      do {
        if let target { try await link.rewind(chat, to: target, keep: replacement == nil) }
      } catch {
        chat.problem = error.localizedDescription
        return
      }
      pinned = true
      guard let replacement else { return }
      // Once the original is gone, the next attempt should send to the fork without rewinding again.
      editing = MessageEdit(target: nil, text: replacement)
      if await link.send(replacement, in: chat) {
        editing = nil
        sent += 1
      } else if chat.problem == nil {
        chat.problem = "Couldn’t send the replacement. Try again."
      }
    }
  }

  /** Straight to spark when it's idle; otherwise to the end of the queue, sent as each turn ends. */
  private func send() {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    if chat.canSend {
      draft = ""
      pinned = true
      sent += 1
      Task { if !(await link.send(text, in: chat)), draft.isEmpty { draft = text } }
    } else if chat.canQueue, link.enqueue(text, in: chat) {
      draft = ""
      sent += 1
    }
  }
}

/** Where the thread is scrolled: how far the bottom is, and where the end lies. */
private struct Fill: Equatable {
  var distance: CGFloat
  var end: CGFloat
  var offset: CGFloat

  init(_ g: ScrollGeometry) {
    // the container leaves out the insets, so the last offset puts the content's end at the bottom inset
    let end = max(-g.contentInsets.top, g.contentSize.height - g.containerSize.height - g.contentInsets.top)
    self.end = end.rounded()
    offset = g.contentOffset.y.rounded()
    distance = self.end - offset
  }
}

/**
 * Moves the thread to its end the way a hand would: a spring pulls the offset toward the bottom a
 * frame at a time. The bottom can move while it pulls, as a reply streams in, and the motion stays
 * one continuous glide instead of a jump per piece of text.
 */
@MainActor
private final class Follower {
  weak var scrollView: UIScrollView?
  private var link: CADisplayLink?
  private var velocity: CGFloat = 0
  /** how firmly it pulls: settles in about a third of a second */
  private let omega: CGFloat = 12

  func glide() {
    guard let view = scrollView else { return }
    // a thread still coasting from a flick stops where it is, and the glide takes over
    if view.isDecelerating { view.setContentOffset(view.contentOffset, animated: false) }
    guard link == nil else { return }
    velocity = 0
    let link = CADisplayLink(target: self, selector: #selector(tick))
    link.add(to: .main, forMode: .common)
    self.link = link
  }

  func stop() {
    link?.invalidate()
    link = nil
    velocity = 0
  }

  @objc private func tick(_ link: CADisplayLink) {
    guard let view = scrollView, view.window != nil, !view.isTracking else { return stop() }
    let dt = min(max(link.targetTimestamp - link.timestamp, 1.0 / 240), 1.0 / 30)
    let target = max(-view.adjustedContentInset.top, view.contentSize.height + view.adjustedContentInset.bottom - view.bounds.height)
    var y = view.contentOffset.y
    // critically damped: as fast as it can get there without passing it
    velocity += (omega * omega * (target - y) - 2 * omega * velocity) * dt
    y += velocity * dt
    if y >= target || (abs(target - y) < 0.5 && abs(velocity) < 8) {
      y = target
      velocity = 0
    }
    view.contentOffset.y = y
    if y == target { stop() }
  }
}

/**
 * Hands over the UIScrollView a SwiftUI ScrollView is drawn in, once it's on screen. With `tap`, a tap
 * on the thread also puts the keyboard away; the tap still reaches buttons, menus and text under it.
 */
private struct ScrollFinder: UIViewRepresentable {
  let found: (UIScrollView) -> Void
  var tap: (() -> Void)? = nil

  func makeUIView(context: Context) -> Probe {
    let probe = Probe()
    probe.found = found
    probe.tap = tap
    return probe
  }

  func updateUIView(_ probe: Probe, context: Context) {
    probe.found = found
    probe.tap = tap
  }

  static func dismantleUIView(_ probe: Probe, coordinator: ()) {
    probe.detach()
  }

  final class Probe: UIView, UIGestureRecognizerDelegate {
    var found: ((UIScrollView) -> Void)?
    var tap: (() -> Void)?
    private lazy var recognizer: UITapGestureRecognizer = {
      let r = UITapGestureRecognizer(target: self, action: #selector(tapped))
      r.cancelsTouchesInView = false
      r.delegate = self
      return r
    }()

    override func didMoveToWindow() {
      super.didMoveToWindow()
      guard window != nil else { return detach() }
      var view = superview
      while let v = view, !(v is UIScrollView) { view = v.superview }
      guard let scroll = view as? UIScrollView else { return }
      found?(scroll)
      if recognizer.view !== scroll {
        detach()
        scroll.addGestureRecognizer(recognizer)
      }
    }

    func detach() {
      recognizer.view?.removeGestureRecognizer(recognizer)
    }

    @objc private func tapped(_ r: UITapGestureRecognizer) {
      if r.state == .ended { tap?() }
    }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool { tap != nil }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
      true
    }
  }
}

enum RowAction { case copy, edit, retry, rewind }

/** A message being changed: the bubble it came from (gone once its turn was dropped) and the new text. */
private struct MessageEdit {
  var target: Entry?
  var text: String
}

/** A change to the chat's history that drops turns, so it asks first. */
private enum HistoryAction: Identifiable {
  case rewind(Entry)
  case retry(Entry)

  var id: String {
    switch self {
    case .rewind(let e): "rewind-\(e.id)"
    case .retry(let e): "retry-\(e.id)"
    }
  }
  var title: String {
    switch self {
    case .rewind: "Go back to this reply?"
    case .retry: "Send this message again?"
    }
  }
  var button: String {
    switch self {
    case .rewind: "Go Back"
    case .retry: "Send Again"
    }
  }
  var message: String {
    switch self {
    case .rewind: "Everything after it leaves the chat."
    case .retry: "The replies after it leave the chat, and spark answers it afresh."
    }
  }
}

/** Above the composer while a message is being edited: what sending will do, and a way out. */
private struct EditingBar: View {
  /** the original turn is already gone: sending only adds the edited message */
  var replacement = false
  let cancel: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: replacement ? "arrow.clockwise" : "pencil")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Effort.accent)
        .contentTransition(.symbolEffect(.replace))
      Text(replacement ? "Not sent yet. Send to try again." : "Editing. Sending replaces it and what came after.")
        .font(.geist(13, .medium))
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .contentTransition(.opacity)
      Spacer(minLength: 4)
      Button(action: cancel) {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .bold))
          .frame(width: 26, height: 26)
          .background(Color.white.opacity(0.1), in: .circle)
          .contentShape(.circle)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Stop editing")
    }
    .foregroundStyle(Color(white: 0.8))
    .padding(.leading, 14)
    .padding(.trailing, 6)
    .frame(height: 38)
    .glassEffect(.regular, in: .capsule)
    .animation(.smooth(duration: 0.25), value: replacement)
  }
}

/** Messages waiting for spark to finish, in the order they go out, with why they're held if they are. */
private struct QueuePanel: View {
  let chat: Chat
  let remove: (String) -> Void
  let resume: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Image(systemName: "text.append").font(.system(size: 11, weight: .semibold))
        Text(status).font(.geist(12, .medium)).lineLimit(2)
        Spacer(minLength: 4)
        if chat.canResumeQueue {
          Button("Resume", action: resume)
            .font(.geist(12, .semibold))
            .buttonStyle(.plain)
            .foregroundStyle(Effort.accent)
            .transition(.opacity)
        }
      }
      .foregroundStyle(Color.dim)
      .padding(.horizontal, 6)
      ForEach(chat.queue) { item in
        QueueRow(text: item.text, sending: chat.queueSending == item.id) { remove(item.id) }
          .transition(QueueRow.transition)
      }
    }
    .padding(8)
    .glassEffect(.regular, in: .rect(cornerRadius: 20, style: .continuous))
    .animation(.spring(duration: 0.35, bounce: 0.1), value: chat.queue.map(\.id))
    .animation(.smooth(duration: 0.2), value: chat.queueSending)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("queue")
  }

  private var status: String {
    let count = chat.queue.count == 1 ? "1 queued" : "\(chat.queue.count) queued"
    switch chat.queuePause {
    case .stopped?: return "\(count) · paused after Stop"
    case .turnFailed?: return "\(count) · paused, the last turn failed"
    case .rejected(let why)?: return "\(count) · not sent: \(why)"
    case .unconfirmed?: return "\(count) · checking whether the last one arrived…"
    case nil: return chat.queueSending != nil ? "Sending…" : "\(count) · sends when spark finishes"
    }
  }
}

private struct QueueRow: View {
  let text: String
  let sending: Bool
  let remove: () -> Void

  static let transition: AnyTransition = .asymmetric(
    insertion: AnyTransition.move(edge: .bottom).combined(with: .opacity),
    removal: AnyTransition.opacity.combined(with: .scale(scale: 0.96))
  )

  var body: some View {
    HStack(spacing: 10) {
      Text(text)
        .font(.geist(14))
        .foregroundStyle(Color(white: 0.85))
        .lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)
      if sending {
        ProgressView().controlSize(.mini).accessibilityLabel("Sending")
      } else {
        Button(action: remove) {
          Image(systemName: "xmark")
            .font(.system(size: 10, weight: .bold))
            .frame(width: 24, height: 24)
            .background(Color.white.opacity(0.1), in: .circle)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove queued message")
      }
    }
    .padding(.leading, 12)
    .padding(.trailing, 6)
    .padding(.vertical, 7)
    .background(Color.white.opacity(0.06), in: .rect(cornerRadius: 14, style: .continuous))
  }
}

/** What the thread lays out: one row, or a run of tool calls folded together. */
private struct Unit: Identifiable {
  enum Kind {
    case one(Entry)
    case tools([Entry])
  }

  let id: String
  let kind: Kind
  let gap: CGFloat

  /** groups by role only, which never changes for a row, so streaming text doesn't rebuild the list */
  static func build(_ entries: [Entry]) -> [Unit] {
    var out: [Unit] = []
    var i = 0
    var prev: Item.Role?
    while i < entries.count {
      let e = entries[i]
      if e.role == .tool {
        var j = i
        while j < entries.count, entries[j].role == .tool { j += 1 }
        let run = Array(entries[i..<j])
        out.append(Unit(id: e.id, kind: run.count == 1 ? .one(e) : .tools(run), gap: gap(prev, .tool)))
        prev = .tool
        i = j
      } else {
        out.append(Unit(id: e.id, kind: .one(e), gap: gap(prev, e.role)))
        prev = e.role
        i += 1
      }
    }
    return out
  }

  /** room above a row: more between turns, less inside one */
  private static func gap(_ prev: Item.Role?, _ role: Item.Role) -> CGFloat {
    guard let prev else { return 0 }
    if role == .user { return 28 }
    if prev == .user { return 18 }
    return 12
  }
}

/** spark is busy but nothing is streaming: its last word was yours, or a tool just finished. */
private struct WorkingLine: View {
  let chat: Chat

  var body: some View {
    if waiting {
      Working()
        .padding(.top, 16)
        .transition(.opacity)
    }
  }

  private var waiting: Bool {
    guard let last = chat.entries.last else { return true }
    switch last.role {
    case .user, .notice: return true
    case .tool: return last.item.status == .completed || last.item.status == .failed
    default: return false
    }
  }
}

/** A new session's empty page: where it runs, and an invitation. */
private struct Fresh: View {
  let folder: String
  let host: HostEntry?
  @State private var shown = false

  var body: some View {
    VStack(spacing: 12) {
      Text("What should we build?")
        .font(.geist(28, .medium, relativeTo: .largeTitle))
        .kerning(-0.8)
        .multilineTextAlignment(.center)
        .textRenderer(DitherIn(progress: shown ? 1 : 0))
      HStack(spacing: 6) {
        Image(systemName: host?.symbol ?? "folder")
        Text(folder).font(.geistMono(13))
      }
      .font(.system(size: 12))
      .foregroundStyle(Color.dim)
      .opacity(shown ? 1 : 0)
    }
    .padding(.horizontal, 32)
    .animation(.easeOut(duration: 0.9), value: shown)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear { shown = true }
  }
}

private struct Row: View {
  let entry: Entry
  let live: Bool
  /** the first message of a chat just started: it settles in under the title */
  var arriving = false
  /** the last answer of its turn: copy, retry and go back sit under it */
  var ends = false
  /** spark isn't working on the chat, so it can go back or try again */
  var changeable = false
  /** a later turn exists, so going back to this reply would drop something */
  var canRewind = false
  /** this message is the one being edited in the composer */
  var editing = false
  let disclose: () -> Void
  var act: (RowAction, Entry) -> Void = { _, _ in }

  var body: some View {
    let item = entry.item
    switch entry.role {
    case .user:
      UserBubble(text: item.text, arriving: arriving, editing: editing) {
        Button("Copy", systemImage: "doc.on.doc") { act(.copy, entry) }
        if changeable {
          Button("Edit", systemImage: "pencil") { act(.edit, entry) }
          Button("Send Again", systemImage: "arrow.clockwise") { act(.retry, entry) }
        }
      }
    case .assistant:
      VStack(alignment: .leading, spacing: 6) {
        StreamingText(text: item.text, streaming: live).textSelection(.enabled)
        if ends, !live {
          ReplyActions(changeable: changeable, canRewind: canRewind) { act($0, entry) }
            .transition(.opacity)
        }
      }
    case .thought: ThoughtRow(text: item.text, live: live, disclose: disclose)
    case .tool: ToolRow(entry: entry, disclose: disclose)
    case .notice:
      Text(item.text)
        .font(.geist(13))
        .foregroundStyle(Color.dim)
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }
  }
}

/** Under the last answer of a turn: copy it, ask again, or take the chat back to it. */
private struct ReplyActions: View {
  let changeable: Bool
  var canRewind = false
  let act: (RowAction) -> Void
  @State private var copied = 0

  var body: some View {
    HStack(spacing: 2) {
      button(copied > 0 ? "checkmark" : "doc.on.doc", "Copy") {
        act(.copy)
        copied += 1
        Task {
          try? await Task.sleep(for: .seconds(1.4))
          copied = 0
        }
      }
      .contentTransition(.symbolEffect(.replace))
      if changeable {
        button("arrow.clockwise", "Try again") { act(.retry) }
          .transition(.opacity)
        if canRewind {
          button("arrow.uturn.backward", "Go back to here") { act(.rewind) }
            .transition(.opacity)
        }
      }
    }
    .padding(.leading, -8)
    .foregroundStyle(Color.faint)
    .sensoryFeedback(.success, trigger: copied) { _, new in new > 0 }
    .animation(.smooth(duration: 0.2), value: changeable)
    .animation(.smooth(duration: 0.2), value: canRewind)
  }

  private func button(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 12.5, weight: .medium))
        .frame(width: 32, height: 28)
        .contentShape(.rect)
    }
    .buttonStyle(QuietPress())
    .accessibilityLabel(label)
  }
}

private struct UserBubble<Menu: View>: View {
  let text: String
  var arriving = false
  var editing = false
  @ViewBuilder var menu: Menu
  @State private var landed = true

  var body: some View {
    HStack {
      Spacer(minLength: 48)
      Text(text)
        .font(.geist(15.5))
        .lineSpacing(3)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(Color.bubble, in: .rect(cornerRadius: 22, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(Effort.accent.opacity(editing ? 0.85 : 0), lineWidth: 1.5)
        }
        .scaleEffect(editing ? 1.015 : 1, anchor: .trailing)
        .animation(.spring(duration: 0.3, bounce: 0.15), value: editing)
        .accessibilityValue(editing ? "Editing" : "")
        .contentShape(.contextMenuPreview, .rect(cornerRadius: 22, style: .continuous))
        .contextMenu { menu }
    }
    .offset(y: landed ? 0 : 18)
    .scaleEffect(landed ? 1 : 0.94, anchor: .topTrailing)
    .blur(radius: landed ? 0 : 10)
    .opacity(landed ? 1 : 0)
    .onAppear {
      guard arriving else { return }
      landed = false
      withAnimation(.spring(duration: 0.5, bounce: 0.12)) { landed = true }
    }
  }
}

/** spark's reasoning: one quiet line that opens to the full text. */
private struct ThoughtRow: View {
  let text: String
  let live: Bool
  let disclose: () -> Void
  @State private var open = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        disclose()
        open.toggle()
      } label: {
        HStack(spacing: 6) {
          Text(live ? "Thinking" : "Thought")
            .font(.geist(14, .medium))
            .contentTransition(.opacity)
            .modifier(MaybeShimmer(on: live))
          Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .bold))
            .rotationEffect(.degrees(open ? 90 : 0))
        }
        .foregroundStyle(Color.dim)
        .padding(.vertical, 2)
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      // laid out only while open: a long chain of thought costs nothing folded away
      if open {
        Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
          .font(.geist(14))
          .lineSpacing(4)
          .foregroundStyle(Color.dim)
          .padding(.leading, 12)
          .overlay(alignment: .leading) { Capsule().fill(Color.hairline).frame(width: 2) }
          .padding(.top, 8)
      }
    }
    .clipped()
    .sensoryFeedback(.selection, trigger: open)
  }
}

private struct MaybeShimmer: ViewModifier {
  let on: Bool
  func body(content: Content) -> some View {
    if on { content.modifier(Shimmer()) } else { content }
  }
}

private struct Working: View {
  var body: some View {
    Text("Working")
      .font(.geist(14, .medium))
      .modifier(Shimmer())
      .foregroundStyle(Color.dim)
  }
}

/** A run of tool calls folded into one line that says what they did; the newest shows while it runs. */
private struct ToolGroup: View {
  let entries: [Entry]
  let live: Bool
  let disclose: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduce
  @State private var open = false
  /** the summary line settles in when a lone call becomes a run of them */
  @State private var header = true

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        disclose()
        withAnimation(.toolDisclose) { open.toggle() }
      } label: {
        HStack(spacing: 9) {
          Image(systemName: "square.stack.3d.up")
            .font(.system(size: 12, weight: .medium))
            .frame(width: 16)
          Text(summary)
            .font(.geist(14, .medium))
            .lineLimit(1)
            // the count ticks over as each call joins the run
            .contentTransition(.numericText())
            .modifier(MaybeShimmer(on: live))
          if failed > 0 {
            Text("\(failed) failed").font(.geist(12)).foregroundStyle(.red.opacity(0.8))
              .transition(.scale(0.8, anchor: .leading).combined(with: .opacity))
          }
          Spacer(minLength: 4)
          Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Color.faint)
            .rotationEffect(.degrees(open ? 90 : 0))
        }
        .foregroundStyle(Color.dim)
        .padding(.vertical, 6)
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .offset(y: header || reduce ? 0 : 6)
      .blur(radius: header || reduce ? 0 : 4)
      .opacity(header ? 1 : 0)
      .accessibilityLabel(summary)
      .accessibilityHint(open ? "Hides the steps" : "Shows each step")

      if open {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(entries) { ToolRow(entry: $0, disclose: disclose) }
        }
        .padding(.leading, 8)
        .overlay(alignment: .leading) { Capsule().fill(Color.hairline).frame(width: 1.5).padding(.vertical, 6) }
        .transition(Settle(distance: reduce ? 0 : -6))
      } else if live, let last = entries.last {
        // the newest call rises into the line as the one before lifts away, both in the same spot
        ZStack(alignment: .topLeading) {
          ToolRow(entry: last, disclose: disclose)
            .id(last.id)
            .transition(.asymmetric(insertion: AnyTransition.identity, removal: AnyTransition(Settle(distance: reduce ? 0 : -10))))
        }
        .transition(Settle(distance: reduce ? 0 : 8))
      }
    }
    .animation(.toolArrive, value: entries.count)
    .animation(.toolArrive, value: failed)
    .animation(.toolArrive, value: live)
    .clipped()
    .sensoryFeedback(.selection, trigger: open)
    .onAppear {
      // only a run that just formed: a chat opened on a long one shows it as it is
      guard live, entries.count == 2, entries.last?.fresh == true else { return }
      header = false
      withAnimation(.toolArrive) { header = true }
    }
  }

  private var failed: Int { entries.filter { $0.item.status == .failed }.count }

  /** "Read 3 files, ran 2 commands" */
  private var summary: String {
    var counts: [(String, Int)] = []
    func add(_ key: String) {
      if let i = counts.firstIndex(where: { $0.0 == key }) { counts[i].1 += 1 } else { counts.append((key, 1)) }
    }
    for e in entries { add(e.item.kind ?? "other") }
    let parts = counts.map { kind, n -> String in
      switch kind {
      case "read": "read \(n) \(n == 1 ? "file" : "files")"
      case "edit": "edited \(n) \(n == 1 ? "file" : "files")"
      case "delete": "deleted \(n) \(n == 1 ? "file" : "files")"
      case "move": "moved \(n) \(n == 1 ? "file" : "files")"
      case "execute": "ran \(n) \(n == 1 ? "command" : "commands")"
      case "search": "searched \(n) \(n == 1 ? "time" : "times")"
      case "fetch": "fetched \(n) \(n == 1 ? "page" : "pages")"
      case "think": "planned"
      default: "used \(n) \(n == 1 ? "tool" : "tools")"
      }
    }
    let text = parts.prefix(3).joined(separator: ", ")
    return text.prefix(1).uppercased() + text.dropFirst()
  }
}

/** One thing spark did: what it ran or touched on one line, the output a tap away. */
private struct ToolRow: View {
  let entry: Entry
  let disclose: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduce
  @State private var open = false
  /** where the row is in its arrival: the icon lands first, the words follow it in from the left */
  @State private var row = true
  @State private var icon = true
  @State private var words = true

  var body: some View {
    let item = entry.item
    VStack(alignment: .leading, spacing: 0) {
      Button {
        guard hasOutput(item) else { return }
        disclose()
        withAnimation(.toolDisclose) { open.toggle() }
      } label: {
        HStack(alignment: .center, spacing: 9) {
          Image(systemName: symbol(item))
            .font(.system(size: 12, weight: .medium))
            .frame(width: 16)
            .foregroundStyle(Color.dim)
            .scaleEffect(icon || reduce ? 1 : 0.4)
            .opacity(icon ? 1 : 0)
          HStack(spacing: 9) {
            Text(verb(item))
              .font(.geist(14, .medium))
              .foregroundStyle(Color.dim)
              .contentTransition(.opacity)
              .modifier(MaybeShimmer(on: !done(item)))
              .layoutPriority(1)
            if let detail = shown(item) {
              Text(detail)
                .font(.geistMono(12.5))
                .foregroundStyle(Color(white: 0.74))
                .lineLimit(1)
                .truncationMode(.middle)
            }
          }
          .offset(x: words || reduce ? 0 : -8)
          .blur(radius: words || reduce ? 0 : 3)
          .opacity(words ? 1 : 0)
          Spacer(minLength: 4)
          status(item)
        }
        .padding(.vertical, 5)
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      // the output is only laid out once asked for: a closed row costs one line
      if open, let output = item.output, hasOutput(item) {
        OutputBlock(text: output)
          .padding(.top, 4)
          .padding(.bottom, 6)
          .transition(Settle(distance: reduce ? 0 : -6))
      }
    }
    .offset(y: row || reduce ? 0 : 8)
    .opacity(row ? 1 : 0)
    .animation(.toolArrive, value: item.status)
    .clipped()
    .sensoryFeedback(.selection, trigger: open)
    .onAppear(perform: arrive)
  }

  /** a call that just came in settles into its line in three quick beats instead of popping in */
  private func arrive() {
    guard entry.fresh else { return }
    row = false
    icon = false
    words = false
    withAnimation(.toolArrive) { row = true }
    withAnimation(.spring(duration: 0.45, bounce: 0.3).delay(0.04)) { icon = true }
    withAnimation(.toolArrive.delay(0.08)) { words = true }
  }

  private func hasOutput(_ item: Item) -> Bool { !(item.output ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  @ViewBuilder private func status(_ item: Item) -> some View {
    switch item.status {
    case .failed:
      Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.red.opacity(0.85))
        .transition(.scale(0.5).combined(with: .opacity))
    case .completed:
      if hasOutput(item) {
        Image(systemName: "chevron.right")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(Color.faint)
          .rotationEffect(.degrees(open ? 90 : 0))
          .transition(.scale(0.5).combined(with: .opacity))
      }
    default:
      EmptyView()
    }
  }

  private func done(_ item: Item) -> Bool { item.status == .completed || item.status == .failed }

  private func verb(_ item: Item) -> String {
    let d = done(item)
    switch item.kind {
    case "execute": return d ? "Ran" : "Running"
    case "read": return d ? "Read" : "Reading"
    case "edit": return d ? "Edited" : "Editing"
    case "delete": return d ? "Deleted" : "Deleting"
    case "move": return d ? "Moved" : "Moving"
    case "search": return d ? "Searched" : "Searching"
    case "fetch": return d ? "Fetched" : "Fetching"
    case "think": return d ? "Planned" : "Planning"
    default:
      let t = item.title ?? item.name ?? "Tool"
      return t == "Running" ? (item.name ?? "Tool") : t
    }
  }

  private func symbol(_ item: Item) -> String {
    switch item.kind {
    case "execute": "terminal"
    case "read": "doc.text"
    case "edit": "pencil"
    case "delete": "trash"
    case "move": "arrow.right"
    case "search": "magnifyingglass"
    case "fetch": "globe"
    case "think": "list.bullet"
    case "mcp": "point.3.connected.trianglepath.dotted"
    default: "wrench.and.screwdriver"
    }
  }

  /** paths read better as their last parts */
  private func shown(_ item: Item) -> String? {
    guard let d = item.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty else { return nil }
    let oneLine = d.replacingOccurrences(of: "\n", with: " ")
    if ["read", "edit", "delete", "move"].contains(item.kind ?? ""), oneLine.hasPrefix("/") {
      return oneLine.split(separator: "/").suffix(2).joined(separator: "/")
    }
    return oneLine
  }
}

private struct OutputBlock: View {
  let text: String

  var body: some View {
    ScrollView([.vertical, .horizontal], showsIndicators: false) {
      Text(text.trimmingCharacters(in: .newlines))
        .font(.geistMono(11.5, relativeTo: .footnote))
        .lineSpacing(2)
        .foregroundStyle(Color(white: 0.72))
        .textSelection(.enabled)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .defaultScrollAnchor(.bottomLeading)
    .frame(maxHeight: 240)
    .fixedSize(horizontal: false, vertical: true)
    .background(Color.well, in: .rect(cornerRadius: 14, style: .continuous))
    .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.hairline) }
    .padding(.leading, 25)
  }
}

/** spark asks before it acts, in Ask mode: what it wants to do, and the answers it takes. */
private struct PermissionCard: View {
  let permission: Permission
  let answer: (String?) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Image(systemName: "hand.raised")
          .font(.system(size: 13, weight: .semibold))
        Text("spark wants to \(permission.title.prefix(1).lowercased() + permission.title.dropFirst())")
          .font(.geist(15, .medium))
          .lineLimit(2)
      }
      if let detail = permission.detail {
        Text(detail)
          .font(.geistMono(13))
          .foregroundStyle(Color(white: 0.8))
          .lineLimit(4)
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.white.opacity(0.06), in: .rect(cornerRadius: 12, style: .continuous))
      }
      HStack(spacing: 8) {
        ForEach(order, id: \.optionId) { o in
          Button(label(o)) { answer(o.optionId) }
            .buttonStyle(PillButton(secondary: o.kind != "allow_once", wide: true))
        }
      }
    }
    .padding(14)
    .glassEffect(.regular, in: .rect(cornerRadius: 24))
  }

  /** reject, always, then the plain yes on the right where the thumb is */
  private var order: [Permission.Option] {
    let rank = ["reject_once": 0, "reject_always": 1, "allow_always": 2, "allow_once": 3]
    return permission.options.sorted { (rank[$0.kind] ?? 9) < (rank[$1.kind] ?? 9) }
  }

  private func label(_ o: Permission.Option) -> String {
    switch o.kind {
    case "allow_once": "Allow"
    case "allow_always": "Always"
    case "reject_once": "Deny"
    default: o.name
    }
  }
}
