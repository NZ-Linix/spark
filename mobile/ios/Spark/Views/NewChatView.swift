import SwiftUI

/** A new chat: pick where it runs, then say what to do. Nothing is remembered between chats. */
struct NewChatView: View {
  @Environment(Link.self) private var link
  @Environment(\.shell) private var shell
  @AppStorage("sidebarStyle") private var style: SidebarStyle = .sections
  /** bumped by the shell when a new chat starts: show the folder picker */
  let ask: Int
  @State private var folder: String?
  /** the folder as it reads, relative to the host's home */
  @State private var label = ""
  /** model and other options chosen before the chat exists; applied once it starts */
  @State private var pending: [String: String] = [:]
  /** a library prompt the chat runs with in place of spark's own */
  @AppStorage("prompt") private var prompt = ""
  @State private var picking = false
  @State private var draft = ""
  @State private var problem: String?
  @State private var shown = false
  @State private var sent = 0
  @FocusState private var focused: Bool

  var body: some View {
    VStack(spacing: 12) {
      Text("What should we build?")
        .font(.geist(30, .medium, relativeTo: .largeTitle))
        .kerning(-0.8)
        .multilineTextAlignment(.center)
        .textRenderer(DitherIn(progress: shown ? 1 : 0))
      // with every host in the sidebar, the chosen host is where new chats go: pick it here
      if style != .switcher, link.hosts.count > 1 {
        HostSwitch()
          .frame(maxWidth: 280)
          .padding(.top, 6)
          .opacity(shown ? 1 : 0)
      } else if let host = link.host {
        Text(host.kind == .cloud ? "in the cloud" : "on \(host.name)")
          .font(.geist(15))
          .foregroundStyle(Color.dim)
          .opacity(shown ? 1 : 0)
          .contentTransition(.opacity)
      }
    }
    .padding(.horizontal, 32)
    // scoped to the words: animating the whole screen would slide the composer in as it's first laid out
    .animation(.easeOut(duration: 0.9), value: shown)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .contentShape(.rect)
    .onTapGesture { focused = false }
    .page()
    .safeAreaInset(edge: .bottom, spacing: 0) {
      VStack(alignment: .leading, spacing: 10) {
        if let problem {
          Text(problem).font(.geist(13)).foregroundStyle(Color.dim).padding(.horizontal, 24).transition(.opacity)
        }
        Composer(text: $draft, focused: $focused, running: false, enabled: link.phase == .online && link.host?.online == true) {
          send()
        } stop: {
        } accessories: {
          // just the folder's own name: the model is the one that gives way when the row is tight
          ComposerOption(text: folder == nil ? "Choose folder" : (label.split(separator: "/").last.map(String.init) ?? label), mono: folder != nil, muted: folder == nil) { picking = true }
          .fixedSize()
          .layoutPriority(1)
          .accessibilityLabel(folder == nil ? "Choose a folder" : "Folder \(label)")
          if !link.prompts.isEmpty {
            PromptChip(prompts: link.prompts, selection: $prompt)
          }
          ConfigChips(options: options) { id, value in pending[id] = value }
        }
      }
      .animation(.ease, value: folder)
      .animation(.ease, value: problem)
    }
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button("Chats", systemImage: "line.3.horizontal") { shell.menu() }
      }
      ToolbarItem(placement: .principal) { Wordmark() }
    }
    .sheet(isPresented: $picking) {
      FolderPicker { path, shown in
        folder = path
        label = shown
        picking = false
        if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { send() } else { focused = true }
      }
    }
    .sensoryFeedback(.impact(weight: .light), trigger: sent)
    .onAppear { shown = true }
    .onChange(of: ask, initial: true) { old, new in
      guard new > 0, new != old || folder == nil else { return }
      folder = nil
      draft = ""
      problem = nil
      picking = true
    }
    .onChange(of: link.hostID) {
      folder = nil
      pending = [:]
    }
    .task(id: "\(link.host?.id ?? "")-\(link.phase == .online)") {
      guard link.phase == .online else { return }
      if let host = link.host?.id { await link.loadOptions(host) }
      if link.hosts.contains(where: { $0.kind == .cloud }) { _ = try? await link.loadPrompts() }
    }
  }

  /** the host's options with this chat's choices laid over them */
  private var options: [ConfigOption] {
    guard let host = link.host?.id else { return [] }
    return (link.configs[host] ?? []).map { o in
      var o = o
      if let v = pending[o.id] { o.currentValue = v }
      return o
    }
  }

  private func send() {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, let host = link.host?.id else { return }
    guard let folder else {
      picking = true
      return
    }
    sent += 1
    let chosen = link.prompts.contains(where: { $0.name == prompt }) ? prompt : nil
    // the chat shows at once with this message in it; the session starts behind it
    link.begin(text, in: folder, on: host, options: pending, prompt: chosen)
    draft = ""
  }
}

/** Which library prompt a new chat runs with; spark's own when none is chosen. */
private struct PromptChip: View {
  let prompts: [PromptSummary]
  @Binding var selection: String

  var body: some View {
    let current = prompts.first { $0.name == selection }
    Menu {
      Picker("Prompt", selection: $selection) {
        Text("spark's own").tag("")
        ForEach(prompts) { p in Text(p.name).tag(p.name) }
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "text.quote").font(.system(size: 11, weight: .semibold))
        Text(current?.name ?? "Prompt")
          .font(.geist(13.5, .medium))
          .lineLimit(1)
        Image(systemName: "chevron.down")
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(Color.faint)
      }
      .foregroundStyle(current == nil ? Color.faint : Color.dim)
      .padding(.horizontal, ComposerOption.slop)
      .frame(height: 30)
      .contentShape(.rect)
    }
    .accessibilityLabel(current.map { "Prompt \($0.name)" } ?? "Choose a prompt")
  }
}
