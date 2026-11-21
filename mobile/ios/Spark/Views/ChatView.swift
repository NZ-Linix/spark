import SwiftUI

/** One session as a conversation: your messages in bubbles, spark's answers and work beneath them. */
struct ChatView: View {
  @Environment(Link.self) private var link
  @Environment(\.shell) private var shell
  let chat: Chat
  @State private var draft = ""
  @FocusState private var focused: Bool
  @State private var sent = 0

  var body: some View {
    ZStack {
      if chat.loaded {
        if chat.items.isEmpty, !chat.running {
          Fresh(folder: chat.info.folder, host: link.hosts.first { $0.id == chat.host })
            .contentShape(.rect)
            .onTapGesture { focused = true }
            .transition(.opacity)
        } else {
          thread.transition(.opacity)
        }
      } else {
        ProgressView().tint(Color.dim).transition(.opacity)
      }
    }
    .animation(.ease, value: chat.loaded)
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
    .onAppear { if chat.loaded, chat.items.isEmpty { focused = true } }
    .onChange(of: chat.loaded) { _, loaded in if loaded, chat.items.isEmpty { focused = true } }
  }

  private var thread: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(Array(chat.items.enumerated()), id: \.element.id) { i, item in
          let prev = i > 0 ? chat.items[i - 1] : nil
          Row(item: item, live: chat.running && i == chat.items.count - 1)
            .padding(.top, gap(prev, item))
            .transition(item.role == .user ? AnyTransition(Rise()) : AnyTransition(Settle(distance: 8)))
        }
        if chat.running, waiting {
          Working()
            .padding(.top, 18)
            .transition(.opacity)
        }
      }
      .padding(.horizontal, 20)
      .padding(.top, 8)
      .padding(.bottom, 24)
      .animation(.spring(duration: 0.5, bounce: 0.12), value: chat.items.count)
      .animation(.ease, value: waiting && chat.running)
    }
    .defaultScrollAnchor(.bottom)
    .defaultScrollAnchor(.bottom, for: .sizeChanges)
    .scrollDismissesKeyboard(.interactively)
  }

  /** spark is busy but nothing is streaming: its last word was yours, or a tool just finished */
  private var waiting: Bool {
    guard let last = chat.items.last else { return true }
    switch last.role {
    case .user, .notice: return true
    case .tool: return last.status == .completed || last.status == .failed
    default: return false
    }
  }

  /** room above a row: more between turns, little between a run of tools */
  private func gap(_ prev: Item?, _ item: Item) -> CGFloat {
    guard let prev else { return 0 }
    if item.role == .user { return 34 }
    if prev.role == .user { return 22 }
    if prev.role == .tool, item.role == .tool { return 2 }
    return 14
  }

  @ToolbarContentBuilder private var toolbar: some ToolbarContent {
    ToolbarItem(placement: .topBarLeading) {
      Button("Chats", systemImage: "line.3.horizontal") { shell.menu() }
    }
    ToolbarItem(placement: .principal) {
      VStack(spacing: 1) {
        Text(chat.info.title)
          .font(.geist(15, .semibold))
          .lineLimit(1)
          .contentTransition(.opacity)
        HStack(spacing: 5) {
          if chat.running { LiveDot() }
          Text(subtitle)
            .font(.geist(12))
            .foregroundStyle(Color.dim)
            .lineLimit(1)
        }
      }
      .frame(maxWidth: 240)
      .animation(.ease, value: chat.info.title)
      .animation(.ease, value: chat.running)
    }
    ToolbarItem(placement: .topBarTrailing) {
      Button("New chat", systemImage: "square.and.pencil") { shell.newChat() }
    }
  }

  private var subtitle: String {
    let host = link.hosts.first { $0.id == chat.host }
    return [chat.info.folder, host?.kind == .cloud ? "Cloud" : nil].compactMap { $0 }.joined(separator: " · ")
  }

  private func send() {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !chat.running else { return }
    sent += 1
    withAnimation(.spring(duration: 0.5, bounce: 0.15)) { draft = "" }
    Task { await link.send(text, in: chat) }
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
        .font(.geist(30, .medium, relativeTo: .largeTitle))
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
  let item: Item
  let live: Bool

  var body: some View {
    switch item.role {
    case .user: UserBubble(text: item.text)
    case .assistant: StreamingText(text: item.text, streaming: live).textSelection(.enabled)
    case .thought: ThoughtRow(text: item.text, live: live)
    case .tool: ToolRow(item: item)
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

  var body: some View {
    HStack {
      Spacer(minLength: 48)
      Text(text)
        .font(.geist(17))
        .lineSpacing(3)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(Color.bubble, in: .rect(cornerRadius: 22, style: .continuous))
        .textSelection(.enabled)
        .contextMenu {
          Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
        }
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
        withAnimation(.spring(duration: 0.38, bounce: 0)) { open.toggle() }
      } label: {
        HStack(spacing: 6) {
          Text(live ? "Thinking" : "Thought")
            .font(.geist(15, .medium))
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
      Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
        .font(.geist(15))
        .lineSpacing(4)
        .foregroundStyle(Color.dim)
        .padding(.leading, 12)
        .overlay(alignment: .leading) { Capsule().fill(Color.hairline).frame(width: 2) }
        .padding(.top, 8)
        .modifier(Reveal(open: open))
    }
    .sensoryFeedback(.selection, trigger: open)
  }
}

/**
 * Folds content away by its height, top edge pinned, so opening and closing slide the rows below
 * smoothly instead of popping. The content stays laid out, just clipped to nothing when shut.
 */
private struct Reveal: ViewModifier {
  let open: Bool
  func body(content: Content) -> some View {
    content
      .fixedSize(horizontal: false, vertical: true)
      .frame(height: open ? nil : 0, alignment: .top)
      .clipped()
      .opacity(open ? 1 : 0)
      .allowsHitTesting(open)
      .accessibilityHidden(!open)
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
        .font(.geist(15, .medium))
        .modifier(Shimmer())
    }
    .foregroundStyle(Color.dim)
  }
}

/** One thing spark did: what it ran or touched on one line, the output a tap away. */
private struct ToolRow: View {
  let item: Item
  @State private var open = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        guard hasOutput else { return }
        withAnimation(.spring(duration: 0.38, bounce: 0)) { open.toggle() }
      } label: {
        HStack(alignment: .center, spacing: 9) {
          Image(systemName: symbol)
            .font(.system(size: 12, weight: .medium))
            .frame(width: 16)
            .foregroundStyle(Color.dim)
          Text(verb)
            .font(.geist(14, .medium))
            .foregroundStyle(Color.dim)
          if let detail = shown {
            Text(detail)
              .font(.geistMono(13))
              .foregroundStyle(Color(white: 0.78))
              .lineLimit(1)
              .truncationMode(.middle)
          }
          Spacer(minLength: 4)
          status
        }
        .padding(.vertical, 6)
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      if hasOutput, let output = item.output {
        OutputBlock(text: output)
          .padding(.top, 6)
          .padding(.bottom, 4)
          .modifier(Reveal(open: open))
      }
    }
    .sensoryFeedback(.selection, trigger: open)
  }

  private var hasOutput: Bool { !(item.output ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  @ViewBuilder private var status: some View {
    switch item.status {
    case .pending, .in_progress:
      ProgressView().controlSize(.mini).tint(Color.dim)
    case .failed:
      Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.red.opacity(0.85))
    default:
      if hasOutput {
        Image(systemName: "chevron.right")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(Color.faint)
          .rotationEffect(.degrees(open ? 90 : 0))
      }
    }
  }

  private var done: Bool { item.status == .completed || item.status == .failed }

  private var verb: String {
    let d = done
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

  private var symbol: String {
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
  private var shown: String? {
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
        .font(.geistMono(12, relativeTo: .footnote))
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
