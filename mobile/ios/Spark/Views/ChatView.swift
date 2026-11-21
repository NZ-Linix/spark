import SwiftUI

/** One session as a conversation: your messages in bubbles, spark's answers and work beneath them. */
struct ChatView: View {
  @Environment(Link.self) private var link
  @Environment(\.shell) private var shell
  let chat: Chat
  @State private var draft = ""
  @FocusState private var focused: Bool
  @State private var sent = 0
  @State private var position = ScrollPosition(edge: .bottom)

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
    .animation(.smooth(duration: 0.3), value: chat.loaded)
    .animation(.smooth(duration: 0.3), value: chat.isEmpty)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .page()
    .safeAreaInset(edge: .bottom, spacing: 0) {
      VStack(spacing: 10) {
        if let p = chat.permission {
          PermissionCard(permission: p) { option in
            Task { await link.answer(chat, p, option: option) }
          }
          .padding(.horizontal, 10)
          .transition(Settle(distance: 24))
        }
        if let problem = chat.problem {
          Text(problem)
            .font(.geist(13))
            .foregroundStyle(Color.dim)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .transition(.opacity)
        }
        Composer(text: $draft, focused: $focused, running: chat.running, enabled: chat.loaded && link.phase == .online) {
          send()
        } stop: {
          Task { await link.cancel(chat) }
        } accessories: {
          ConfigChips(options: chat.config) { id, value in Task { await link.set(chat, id, to: value) } }
        }
      }
      .animation(.spring(duration: 0.45, bounce: 0.18), value: chat.permission)
      .animation(.smooth, value: chat.problem)
    }
    .navigationBarTitleDisplayMode(.inline)
    .toolbar { toolbar }
    .sensoryFeedback(.impact(weight: .light), trigger: sent)
    .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.6), trigger: chat.finished)
    .sensoryFeedback(trigger: chat.permission?.id) { _, new in new == nil ? nil : .warning }
    .onAppear { if chat.loaded, chat.isEmpty, !chat.running { focused = true } }
    .onChange(of: chat.loaded) { _, loaded in if loaded, chat.isEmpty { focused = true } }
  }

  private var thread: some View {
    let units = Unit.build(chat.entries)
    let liveID = chat.running ? chat.entries.last?.id : nil
    let first = chat.starting ? chat.entries.first?.id : nil
    return ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(units) { unit in
          Group {
            switch unit.kind {
            case .one(let entry):
              Row(entry: entry, live: entry.id == liveID, arriving: entry.id == first)
            case .tools(let entries):
              ToolGroup(entries: entries, live: entries.last?.id == liveID)
            }
          }
          .padding(.top, unit.gap)
          .transition(unit.role == .user ? AnyTransition(Rise()) : AnyTransition(Settle(distance: 8)))
        }
        if chat.running {
          WorkingLine(chat: chat)
        }
      }
      .padding(.horizontal, 18)
      .padding(.top, 8)
      .padding(.bottom, 24)
      .animation(.smooth(duration: 0.35), value: units.count)
    }
    .scrollPosition($position)
    .defaultScrollAnchor(.bottom)
    .defaultScrollAnchor(.bottom, for: .sizeChanges)
    .scrollDismissesKeyboard(.interactively)
    // a tap anywhere in the thread puts the keyboard away; buttons and links still get theirs
    .simultaneousGesture(TapGesture().onEnded { focused = false })
  }

  @ToolbarContentBuilder private var toolbar: some ToolbarContent {
    ToolbarItem(placement: .topBarLeading) {
      Button("Chats", systemImage: "line.3.horizontal") { shell.menu() }
    }
    ToolbarItem(placement: .principal) {
      Text(chat.info.title)
        .font(.geist(15, .semibold))
        .lineLimit(1)
        .contentTransition(.opacity)
        .frame(maxWidth: 240)
        .animation(.ease, value: chat.info.title)
    }
    ToolbarItem(placement: .topBarTrailing) {
      Button("New chat", systemImage: "square.and.pencil") { shell.newChat() }
    }
  }

  private func send() {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !chat.running else { return }
    sent += 1
    draft = ""
    withAnimation(.smooth(duration: 0.3)) { position.scrollTo(edge: .bottom) }
    Task { await link.send(text, in: chat) }
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
  let role: Item.Role
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
        out.append(Unit(id: e.id, kind: run.count == 1 ? .one(e) : .tools(run), role: .tool, gap: gap(prev, .tool)))
        prev = .tool
        i = j
      } else {
        out.append(Unit(id: e.id, kind: .one(e), role: e.role, gap: gap(prev, e.role)))
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
  /** the first message of a chat just started: it rises from the composer */
  var arriving = false

  var body: some View {
    let item = entry.item
    switch entry.role {
    case .user: UserBubble(text: item.text, arriving: arriving)
    case .assistant: StreamingText(text: item.text, streaming: live).textSelection(.enabled)
    case .thought: ThoughtRow(text: item.text, live: live)
    case .tool: ToolRow(entry: entry)
    case .notice:
      Text(item.text)
        .font(.geist(13))
        .foregroundStyle(Color.dim)
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }
  }
}

private struct UserBubble: View {
  let text: String
  var arriving = false
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
        .textSelection(.enabled)
        .contextMenu {
          Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
        }
    }
    .offset(y: landed ? 0 : 120)
    .scaleEffect(landed ? 1 : 0.94, anchor: .bottomTrailing)
    .opacity(landed ? 1 : 0)
    .onAppear {
      guard arriving else { return }
      landed = false
      withAnimation(.spring(duration: 0.5, bounce: 0.16)) { landed = true }
    }
  }
}

/** spark's reasoning: one quiet line that opens to the full text. */
private struct ThoughtRow: View {
  let text: String
  let live: Bool
  @State private var open = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(.snappy(duration: 0.3)) { open.toggle() }
      } label: {
        HStack(spacing: 6) {
          Text(live ? "Thinking" : "Thought")
            .font(.geist(14, .medium))
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
          .transition(.opacity.combined(with: .move(edge: .top)))
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

/** spark is between steps: a terminal's block cursor, blinking while it waits. */
private struct Working: View {
  @State private var on = true

  var body: some View {
    HStack(spacing: 8) {
      RoundedRectangle(cornerRadius: 1.5)
        .fill(Color.dim)
        .frame(width: 8, height: 15)
        .opacity(on ? 1 : 0.15)
        .onAppear { withAnimation(.easeInOut(duration: 0.5).repeatForever()) { on = false } }
      Text("Working")
        .font(.geist(14, .medium))
        .modifier(Shimmer())
    }
    .foregroundStyle(Color.dim)
  }
}

/** A run of tool calls folded into one line that says what they did; the newest shows while it runs. */
private struct ToolGroup: View {
  let entries: [Entry]
  let live: Bool
  @State private var open = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(.snappy(duration: 0.3)) { open.toggle() }
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
          ForEach(entries) { ToolRow(entry: $0) }
        }
        .padding(.leading, 8)
        .overlay(alignment: .leading) { Capsule().fill(Color.hairline).frame(width: 1.5).padding(.vertical, 6) }
        .transition(.opacity.combined(with: .move(edge: .top)))
      } else if live, let last = entries.last {
        ToolRow(entry: last)
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
  @State private var open = false

  var body: some View {
    let item = entry.item
    VStack(alignment: .leading, spacing: 0) {
      Button {
        guard hasOutput(item) else { return }
        withAnimation(.snappy(duration: 0.3)) { open.toggle() }
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
          .transition(.opacity.combined(with: .move(edge: .top)))
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
