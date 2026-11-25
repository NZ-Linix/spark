import SwiftUI

/** A new chat: pick where it runs, then say what to do. Nothing is remembered between chats. */
struct NewChatView: View {
  /** the switch's 36-point track, its 3-point rim, and the 6 points above it */
  private static let switchHeight: CGFloat = 48
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
  @State private var mcpDisabled: Set<String> = []
  /** the effort last picked on any host: a new chat starts there on whichever host it runs */
  @AppStorage("effort") private var lastEffort = ""
  /** a library prompt the chat runs with in place of spark's own */
  @AppStorage("prompt") private var prompt = ""
  @State private var picking = false
  @State private var draft = ""
  @State private var problem: String?
  @State private var shown = false
  @State private var sent = 0
  /** sent: the headline dissolves before the chat takes the screen */
  @State private var leaving = false
  @State private var browsing = false
  /** kept while this screen is up, so a command keeps running with the terminal closed */
  @State private var terminal: Terminal?
  @State private var typing: Terminal?
  @FocusState private var focused: Bool
  /** the host switch is drawn under the headline; lags `wantsSwitch` so the swap happens in place first */
  @State private var showsSwitch = false
  /** the room under the headline is the switch's; follows the swap a beat later, so the headline moves last */
  @State private var tall = false
  @State private var lineHeight: CGFloat = 20
  /** bumped each time Macs come or go, so an older swap still in flight stands down */
  @State private var swap = 0

  /** with every host in the sidebar, the chosen host is where new chats go: pick it here */
  private var wantsSwitch: Bool { style != .switcher && link.pickable.count > 1 }

  var body: some View {
    VStack(spacing: 12) {
      Text("What should we build?")
        .font(.geist(30, .medium, relativeTo: .largeTitle))
        .kerning(-0.8)
        .multilineTextAlignment(.center)
        .textRenderer(DitherIn(progress: shown ? 1 : 0))
      // The switch and the line naming the one host trade places in a slot of fixed height, so the
      // headline holds still; then the slot takes its new height and the headline glides to its place
      ZStack(alignment: .top) {
        if showsSwitch {
          HostSwitch()
            .frame(maxWidth: 280)
            .padding(.top, 6)
            .transition(Settle(distance: 6))
        } else if let host = link.host {
          Text(host.kind == .cloud ? "in the cloud" : "on \(host.name)")
            .font(.geist(15))
            .foregroundStyle(Color.dim)
            .contentTransition(.opacity)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { lineHeight = $0 }
            .transition(Settle(distance: 6))
        }
      }
      .frame(height: tall ? Self.switchHeight : lineHeight, alignment: .top)
      .opacity(shown ? 1 : 0)
      .animation(.smooth(duration: 0.3), value: link.host?.id)
    }
    .padding(.horizontal, 32)
    // scoped to the words: animating the whole screen would slide the composer in as it's first laid out
    .animation(.easeOut(duration: 0.9), value: shown)
    .opacity(leaving ? 0 : 1)
    .blur(radius: leaving ? 12 : 0)
    .scaleEffect(leaving ? 0.96 : 1)
    .animation(.smooth(duration: 0.28), value: leaving)
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
          // the folder's own name; how the chat runs sits in the box, beside the send button
          ComposerOption(text: folder == nil ? "Choose folder" : (label.split(separator: "/").last.map(String.init) ?? label), mono: folder != nil, muted: folder == nil) { picking = true }
          .accessibilityLabel(folder == nil ? "Choose a folder" : "Folder \(label)")
        } trailing: {
          ConfigChips(options: options, set: { id, value in
            pending[id] = value
            if id == "effort" { lastEffort = value }
          }, prompts: link.prompts, prompt: $prompt, mcpNames: link.mcpServers[link.host?.id ?? ""] ?? [],
            mcpDisabled: $mcpDisabled, refreshMcp: { if let host = link.host?.id { await link.loadMcpServers(host) } }, compact: true)
        }
      }
      .animation(.ease, value: folder)
      .animation(.ease, value: problem)
      .readable()
    }
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button("Chats", systemImage: shell.menuSymbol) { shell.menu() }
      }
      ToolbarItem(placement: .principal) { Wordmark() }
      // the chosen folder can be looked through and worked in before the chat starts
      if let folder, let host = link.host?.id {
        ToolbarItemGroup(placement: .topBarTrailing) {
          Button("Files", systemImage: "folder") {
            focused = false
            browsing = true
          }
          Button("Terminal", systemImage: "apple.terminal") {
            focused = false
            if terminal?.host != host || terminal?.root != folder { terminal = Terminal(host: host, root: folder) }
            typing = terminal
          }
        }
      }
    }
    .sheet(isPresented: $browsing) {
      if let folder, let host = link.host?.id { FilesView(host: host, root: folder) }
    }
    .sheet(item: $typing) { TerminalView(terminal: $0) }
    .sheet(isPresented: $picking) {
      FolderPicker { path, shown in
        folder = path
        label = shown
        picking = false
        if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { send() } else { focused = true }
      }
    }
    .sensoryFeedback(.impact(weight: .light), trigger: sent)
    .onAppear {
      shown = true
      showsSwitch = wantsSwitch
      tall = wantsSwitch
    }
    .onChange(of: wantsSwitch) { _, want in
      swap += 1
      let mine = swap
      Task {
        // appearing: make room first, then the switch fades into it; leaving: the reverse
        if want {
          withAnimation(.spring(duration: 0.45, bounce: 0)) { tall = true }
        } else {
          withAnimation(.smooth(duration: 0.25)) { showsSwitch = false }
        }
        try? await Task.sleep(for: .milliseconds(want ? 220 : 320))
        guard mine == swap else { return }
        if want {
          withAnimation(.smooth(duration: 0.25)) { showsSwitch = true }
        } else {
          withAnimation(.spring(duration: 0.45, bounce: 0)) { tall = false }
        }
      }
    }
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
      mcpDisabled = []
    }
    .task(id: "\(link.host?.id ?? "")-\(link.phase == .online)") {
      guard link.phase == .online else { return }
      if let host = link.host?.id {
        async let list: Void = link.loadMcpServers(host)
        async let options: Void = link.loadOptions(host)
        _ = await (list, options)
      }
      if link.hosts.contains(where: { $0.kind == .cloud }) { _ = try? await link.loadPrompts() }
    }
  }

  /** the host's options with this chat's choices laid over them */
  private var options: [ConfigOption] {
    guard let host = link.host?.id else { return [] }
    return (link.configs[host] ?? []).map { o in
      var o = o
      if let v = pending[o.id] {
        o.currentValue = v
      } else if o.id == "context" {
        o.currentValue = "auto"
      } else if o.id == "effort", let level = Effort.fallback(o, last: lastEffort) {
        o.currentValue = level
      }
      return o
    }
  }

  private func send() {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, let host = link.host?.id else { return }
    // no folder chosen: the chat runs in a new folder of its own on the host
    guard !leaving else { return }
    sent += 1
    let typing = focused
    focused = false
    draft = ""
    leaving = true
    let chosen = link.prompts.contains(where: { $0.name == prompt }) ? prompt : nil
    var options = pending
    pending.removeValue(forKey: "context")
    if let effort = self.options.first(where: { $0.id == "effort" }), Effort.current(effort) != nil {
      options["effort"] = effort.currentValue
    }
    Task {
      // the keyboard and the headline go first, so the chat opens onto a still screen instead of
      // landing while everything under it moves; the session starts behind the message
      try? await Task.sleep(for: .milliseconds(typing ? 300 : 180))
      link.begin(text, in: folder, on: host, options: options, prompt: chosen, mcpDisabled: mcpDisabled)
    }
  }
}
