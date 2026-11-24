import SwiftUI

/** One session as a conversation: your messages in bubbles, spark's answers and work beneath them. */
struct ChatView: View {
  @Environment(Link.self) private var link
  @Environment(\.shell) private var shell
  let chat: Chat
  @State private var draft = ""
  @FocusState private var focused: Bool
  @State private var sent = 0
  /** following the newest text: on at the bottom, off once you scroll up, on again back down */
  @State private var pinned = true
  /** a finger is on the thread, or it's still gliding from one */
  @State private var scrolling = false
  /** far enough up that a button back down helps */
  @State private var away = false
  /** the message being edited: sending goes back to just before it and sends the new text */
  @State private var editing: Entry?
  /** the reply to go back to, once confirmed */
  @State private var rewindTo: Entry?
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
    .confirmationDialog("Go back to this reply?", isPresented: Binding(get: { rewindTo != nil }, set: { if !$0 { rewindTo = nil } }), titleVisibility: .visible) {
      Button("Go Back", role: .destructive) {
        if let entry = rewindTo { rewind(to: entry) }
      }
    } message: {
      Text("Everything after it leaves the chat.")
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
      if editing != nil {
        EditingBar {
          editing = nil
          draft = ""
        }
        .padding(.horizontal, 14)
        .transition(Settle(distance: 12))
      }
      Composer(
        text: $draft, focused: $focused, running: chat.running && (!chat.elsewhere || chat.terminalOwner != nil),
        enabled: chat.loaded && (!chat.elsewhere || chat.terminalOwner != nil) && !chat.rewinding && link.phase == .online,
        placeholder: editing == nil ? "Message spark" : "Edit your message",
        working: chat.terminalOwner != nil ? "Message the Mac…" : "spark is working…",
        canSendWhileRunning: chat.terminalOwner != nil,
        actionEnabled: !chat.sending && !chat.changingMcp
      ) {
        send()
      } stop: {
        Task { await link.cancel(chat) }
      } trailing: {
        ConfigChips(options: chat.config, set: { id, value in
          if id == "effort" { UserDefaults.standard.set(value, forKey: "effort") }
          Task { await link.set(chat, id, to: value) }
        }, prompts: link.prompts, prompt: promptBinding, mcpNames: link.mcpServers[chat.host] ?? [],
          mcpDisabled: Binding(get: { chat.mcpDisabled }, set: { disabled in Task { await link.setMcp(chat, disabled: disabled) } }),
          mcpEditable: !chat.running && !chat.changingMcp, refreshMcp: { await link.loadMcpServers(chat.host) }, compact: true)
      }
    }
    .readable()
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
    guard chat.elsewhere else { return nil }
    let name = link.hosts.first { $0.id == chat.host }?.name ?? "the Mac"
    if chat.terminalOwner != nil { return "Live on \(name)" }
    return "Open in spark on \(name). Close it there to write here."
  }

  /** what a row's menu can do now: nothing changes the chat while spark works on it */
  private var changeable: Bool {
    !chat.running && !chat.elsewhere && !chat.starting && !chat.rewinding && !chat.info.id.isEmpty && link.phase == .online
  }

  private var thread: some View {
    let units = Unit.build(chat.entries)
    let liveID = chat.running ? chat.entries.last?.id : nil
    let first = chat.starting ? chat.entries.first?.id : nil
    let ends = turnEnds
    // while a message is being edited, it and everything after it fade: sending replaces them
    let cut = editing.flatMap { e in chat.entries.firstIndex { $0.id == e.id } }
    let order = cut == nil ? [:] : Dictionary(uniqueKeysWithValues: chat.entries.enumerated().map { ($1.id, $0) })
    return ScrollViewReader { reader in
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(units) { unit in
            Group {
              switch unit.kind {
              case .one(let entry):
                Row(entry: entry, live: entry.id == liveID, arriving: entry.id == first, ends: ends.contains(entry.id), changeable: changeable, disclose: pauseFollowing, act: act)
              case .tools(let entries):
                ToolGroup(entries: entries, live: entries.last?.id == liveID, disclose: pauseFollowing)
              }
            }
            .padding(.top, unit.gap)
            .opacity(cut.map { (order[unit.id] ?? 0) >= $0 ? 0.3 : 1 } ?? 1)
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
      }
      // going back to an earlier message lays the thread out afresh, from the bottom
      .id(chat.epoch)
      .transition(.opacity)
      .defaultScrollAnchor(.bottom, for: .initialOffset)
      // a short chat reads from the top, so a new one starts under the title and grows down
      .defaultScrollAnchor(.top, for: .alignment)
      .scrollDismissesKeyboard(.interactively)
      .onScrollPhaseChange { _, phase in
        scrolling = phase == .tracking || phase == .interacting || phase == .decelerating
      }
      .onScrollGeometryChange(for: Fill.self, of: Fill.init) { old, new in
        if scrolling, new.offset != old.offset { pinned = new.distance < 44 }
        if away != (new.distance > 160) { away = new.distance > 160 }
        if pinned, !scrolling, new.end != old.end, new.distance > 1 { follow(reader) }
      }
      .onChange(of: chat.epoch) { _, _ in follow(reader) }
      .onChange(of: sent) { _, _ in follow(reader) }
      .overlay(alignment: .bottom) {
        if away && !pinned {
          Button {
            pinned = true
            follow(reader)
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
        if chat.rewinding {
          ProgressView().tint(Color.dim).transition(.opacity)
        }
      }
      .animation(.smooth(duration: 0.2), value: chat.rewinding)
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

  private func follow(_ reader: ScrollViewProxy) {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) { reader.scrollTo("chat-bottom", anchor: .bottom) }
  }

  private func pauseFollowing() { pinned = false }

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
      guard changeable else { return }
      editing = entry
      draft = entry.item.text
      focused = true
    case .retry:
      guard changeable, let prompt = entry.role == .user ? entry : chat.prompt(before: entry) else { return }
      resend(prompt, text: prompt.item.text)
    case .rewind:
      guard changeable else { return }
      rewindTo = entry
    }
  }

  /** goes back to just after `entry`, a reply: the turns after it leave the chat */
  private func rewind(to entry: Entry) {
    rewindTo = nil
    editing = nil
    pinned = true
    Task {
      do {
        try await link.rewind(chat, to: entry, keep: true)
      } catch {
        chat.problem = error.localizedDescription
      }
    }
  }

  /** goes back to just before `prompt` and sends `text` in its place */
  private func resend(_ prompt: Entry, text: String) {
    sent += 1
    pinned = true
    Task {
      do {
        try await link.rewind(chat, to: prompt, keep: false)
        await link.send(text, in: chat)
      } catch {
        chat.problem = error.localizedDescription
        if draft.isEmpty { draft = text }
      }
    }
  }

  private func send() {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, chat.canSend, !chat.rewinding, !chat.changingMcp else { return }
    draft = ""
    pinned = true
    if let target = editing {
      editing = nil
      resend(target, text: text)
      return
    }
    sent += 1
    Task { if !(await link.send(text, in: chat)), draft.isEmpty { draft = text } }
  }
}

/** Where the thread is scrolled: how far the bottom is, and where the end lies. */
private struct Fill: Equatable {
  var distance: CGFloat
  var end: CGFloat
  var offset: CGFloat

  init(_ g: ScrollGeometry) {
    let end = max(-g.contentInsets.top, g.contentSize.height + g.contentInsets.bottom - g.containerSize.height)
    self.end = end.rounded()
    offset = g.contentOffset.y.rounded()
    distance = self.end - offset
  }
}

enum RowAction { case copy, edit, retry, rewind }

/** Above the composer while a message is being edited: what sending will do, and a way out. */
private struct EditingBar: View {
  let cancel: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "pencil")
        .font(.system(size: 12, weight: .semibold))
      Text("Editing. Sending replaces it and what came after.")
        .font(.geist(13, .medium))
        .lineLimit(1)
        .minimumScaleFactor(0.85)
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
  let disclose: () -> Void
  var act: (RowAction, Entry) -> Void = { _, _ in }

  var body: some View {
    let item = entry.item
    switch entry.role {
    case .user:
      UserBubble(text: item.text, arriving: arriving) {
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
          ReplyActions(changeable: changeable) { act($0, entry) }
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
        button("arrow.uturn.backward", "Go back to here") { act(.rewind) }
      }
    }
    .padding(.leading, -8)
    .foregroundStyle(Color.faint)
    .sensoryFeedback(.success, trigger: copied) { _, new in new > 0 }
    .animation(.smooth(duration: 0.2), value: changeable)
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
  @State private var open = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        disclose()
        open.toggle()
      } label: {
        HStack(spacing: 9) {
          Image(systemName: "square.stack.3d.up")
            .font(.system(size: 12, weight: .medium))
            .frame(width: 16)
          Text(summary)
            .font(.geist(14, .medium))
            .lineLimit(1)
            .modifier(MaybeShimmer(on: live))
          if failed > 0 {
            Text("\(failed) failed").font(.geist(12)).foregroundStyle(.red.opacity(0.8))
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
      .accessibilityLabel(summary)
      .accessibilityHint(open ? "Hides the steps" : "Shows each step")

      if open {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(entries) { ToolRow(entry: $0, disclose: disclose) }
        }
        .padding(.leading, 8)
        .overlay(alignment: .leading) { Capsule().fill(Color.hairline).frame(width: 1.5).padding(.vertical, 6) }
      } else if live, let last = entries.last {
        ToolRow(entry: last, disclose: disclose)
          .id(last.id)
          .transition(.opacity)
      }
    }
    .clipped()
    .sensoryFeedback(.selection, trigger: open)
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
  @State private var open = false

  var body: some View {
    let item = entry.item
    VStack(alignment: .leading, spacing: 0) {
      Button {
        guard hasOutput(item) else { return }
        disclose()
        open.toggle()
      } label: {
        HStack(alignment: .center, spacing: 9) {
          Image(systemName: symbol(item))
            .font(.system(size: 12, weight: .medium))
            .frame(width: 16)
            .foregroundStyle(Color.dim)
          Text(verb(item))
            .font(.geist(14, .medium))
            .foregroundStyle(Color.dim)
            .modifier(MaybeShimmer(on: !done(item)))
            .layoutPriority(1)
          if let detail = shown(item) {
            Text(detail)
              .font(.geistMono(12.5))
              .foregroundStyle(Color(white: 0.74))
              .lineLimit(1)
              .truncationMode(.middle)
          }
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
      }
    }
    .clipped()
    .sensoryFeedback(.selection, trigger: open)
  }

  private func hasOutput(_ item: Item) -> Bool { !(item.output ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  @ViewBuilder private func status(_ item: Item) -> some View {
    switch item.status {
    case .failed:
      Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.red.opacity(0.85))
    case .completed:
      if hasOutput(item) {
        Image(systemName: "chevron.right")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(Color.faint)
          .rotationEffect(.degrees(open ? 90 : 0))
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
    .overlay(alignment: .topTrailing) {
      CopyButton(text: text)
        .labelStyle(.iconOnly)
        .font(.system(size: 12))
        .foregroundStyle(Color.dim)
        .padding(10)
    }
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
