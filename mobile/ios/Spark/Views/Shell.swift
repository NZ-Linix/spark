import SwiftUI

/** What any screen can ask of the shell around it. */
struct ShellActions {
  var menu: () -> Void = {}
  var newChat: () -> Void = {}
  /** the sidebar sits beside the chat (an iPad, or any wide window): the menu button shows or hides it */
  var docked = false
}

extension EnvironmentValues {
  @Entry var shell = ShellActions()
}

extension ShellActions {
  /** the menu button's symbol: a sidebar beside the chat, or the list that slides in over it */
  var menuSymbol: String { docked ? "sidebar.left" : "line.3.horizontal" }
}

/** How wide a chat's text and composer grow: past this, lines get too long to read. */
enum Reading {
  static let width: CGFloat = 760
}

extension View {
  /** at most the reading width, centered in whatever room there is */
  func readable(_ width: CGFloat = Reading.width) -> some View {
    frame(maxWidth: width).frame(maxWidth: .infinity)
  }
}

/**
 * The app once paired. On a phone the open chat fills the screen, and the sidebar of chats slides
 * in from the left: swipe right anywhere to open it, left to close it; it follows the finger and
 * settles by speed. In a wide window, as on an iPad, the sidebar stays beside the chat instead, and
 * the menu button tucks it away or brings it back.
 */
struct Shell: View {
  @Environment(Link.self) private var link
  @Environment(\.horizontalSizeClass) private var sizeClass
  @State private var open = false
  @State private var drag: CGFloat = 0
  @State private var showSettings = false
  @State private var showPair = false
  @State private var opened = 0
  /** bumped to show the folder picker for a new chat */
  @State private var newChat = 0
  /** in a wide window: the sidebar is out beside the chat */
  @AppStorage("sidebarDocked") private var docked = true

  /** the narrowest window that keeps the sidebar beside the chat */
  private static let splitWidth: CGFloat = 700
  private static let dockedWidth: CGFloat = 320

  var body: some View {
    GeometryReader { geo in
      let wide = sizeClass == .regular && geo.size.width >= Self.splitWidth
      Group {
        if wide { split } else { overlay(geo.size.width) }
      }
      .environment(\.shell, ShellActions(menu: { wide ? toggleDock() : set(true) }, newChat: startNew, docked: wide))
      .background {
        // a hardware keyboard's shortcuts, whatever has focus
        Group {
          Button("New Chat", action: startNew).keyboardShortcut("n", modifiers: .command)
          Button("Show Chats") { wide ? toggleDock() : set(!open) }.keyboardShortcut("s", modifiers: [.command, .control])
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
      }
    }
    .page()
    .sensoryFeedback(.impact(weight: .light), trigger: opened)
    .sheet(isPresented: $showSettings) { SettingsView(pair: { showSettings = false; showPair = true }) }
    .sheet(isPresented: $showPair) { PairView() }
  }

  /** the sidebar beside the chat, with a hairline between them */
  private var split: some View {
    HStack(spacing: 0) {
      if docked {
        sidebar(visible: true, close: {})
          .frame(width: Self.dockedWidth)
          .background(Color(white: 0.035).ignoresSafeArea())
          .overlay(alignment: .trailing) {
            Rectangle().fill(Color.hairline).frame(width: 1).ignoresSafeArea()
          }
          .transition(.move(edge: .leading).combined(with: .opacity))
      }
      main
        .frame(maxWidth: .infinity)
    }
  }

  /** the phone's layout: the chat on top, the sidebar under it, pulled out by a swipe */
  private func overlay(_ full: CGFloat) -> some View {
    let width = min(full * 0.84, 340)
    let progress = max(0, min(1, ((open ? width : 0) + drag) / width))
    return ZStack(alignment: .leading) {
      sidebar(visible: open, close: { set(false) })
        .frame(width: width)
        .offset(x: (progress - 1) * width * 0.35)
        .opacity(0.4 + progress * 0.6)
        .accessibilityHidden(progress < 0.5)

      main
        .frame(width: full)
        .clipShape(.rect(cornerRadius: progress > 0 ? 38 * progress : 0, style: .continuous))
        .overlay {
          Color.black.opacity(0.45 * progress)
            .ignoresSafeArea()
            .allowsHitTesting(progress > 0.01)
            .onTapGesture { set(false) }
        }
        .offset(x: progress * width)
        .accessibilityHidden(progress >= 0.5)
        // full height always: the corner clip mustn't cut what reaches into the bottom inset
        .ignoresSafeArea(.container, edges: .vertical)
    }
    .background(SidebarSwipe(open: open, began: began, changed: { dx in
      drag = open ? min(0, dx) : max(0, dx)
    }, ended: { dx, vx in
      set((open ? width : 0) + dx + vx * 0.2 > width / 2)
    }))
  }

  private func sidebar(visible: Bool, close: @escaping () -> Void) -> some View {
    Sidebar(visible: visible, close: close, newChat: startNew, cleared: clear, settings: { showSettings = true }, pair: { showPair = true })
  }

  @ViewBuilder private var main: some View {
    NavigationStack {
      if let chat = link.chat {
        // the chat's own identity: a new chat keeps its screen when the host gives it an id
        ChatView(chat: chat).id(ObjectIdentifier(chat))
      } else {
        NewChatView(ask: newChat)
      }
    }
    .page()
  }

  private func startNew() {
    set(false)
    // no animation: inside one, the new screen's composer would grow into place as it's laid out
    link.chat = nil
    newChat += 1
  }

  /** the open chat is gone: a blank new chat takes its place, the sidebar stays, no folder picker */
  private func clear() {
    newChat = 0
    link.chat = nil
  }

  private func toggleDock() {
    if !docked {
      opened += 1
    }
    withAnimation(.spring(duration: 0.38, bounce: 0.08)) { docked.toggle() }
  }

  private func set(_ value: Bool) {
    if value, !open {
      opened += 1
      UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
    withAnimation(.spring(duration: 0.38, bounce: 0.08)) {
      open = value
      drag = 0
    }
  }

  private func began() {
    guard !open else { return }
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
  }
}

/**
 * The swipe that opens and closes the sidebar. It sits on the window, so it sees a swipe wherever it
 * starts, buttons and lists included, and it looks at what's under the finger first: it stays out of
 * the way of text being edited or selected (the caret, the handles, the loupe), of a press that was
 * held before it moved, of a code block that can still scroll back, and of any sheet on top.
 */
private struct SidebarSwipe: UIViewRepresentable {
  let open: Bool
  let began: () -> Void
  let changed: (CGFloat) -> Void
  let ended: (_ dx: CGFloat, _ velocity: CGFloat) -> Void

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> Anchor {
    let anchor = Anchor()
    anchor.isUserInteractionEnabled = false
    anchor.pan = context.coordinator.pan
    return anchor
  }

  func updateUIView(_ view: Anchor, context: Context) {
    context.coordinator.swipe = self
  }

  static func dismantleUIView(_ view: Anchor, coordinator: Coordinator) {
    coordinator.pan.view?.removeGestureRecognizer(coordinator.pan)
  }

  /** puts the recognizer on whatever window it ends up in */
  final class Anchor: UIView {
    var pan: UIPanGestureRecognizer?
    override func didMoveToWindow() {
      super.didMoveToWindow()
      guard let pan, let window, pan.view !== window else { return }
      pan.view?.removeGestureRecognizer(pan)
      window.addGestureRecognizer(pan)
    }
  }

  final class Coordinator: NSObject, UIGestureRecognizerDelegate {
    var swipe: SidebarSwipe?
    let pan = UIPanGestureRecognizer()
    private weak var touched: UIView?
    private var down: TimeInterval = 0
    private var start: CGPoint = .zero

    override init() {
      super.init()
      pan.maximumNumberOfTouches = 1
      pan.delegate = self
      pan.addTarget(self, action: #selector(moved))
    }

    @objc private func moved(_ pan: UIPanGestureRecognizer) {
      guard let swipe else { return }
      let dx = pan.translation(in: nil).x
      switch pan.state {
      case .began: swipe.began(); swipe.changed(dx)
      case .changed: swipe.changed(dx)
      case .ended: swipe.ended(dx, pan.velocity(in: nil).x)
      case .cancelled, .failed: swipe.ended(0, 0)
      default: break
      }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
      // not through a sheet
      if g.view?.window?.rootViewController?.presentedViewController != nil { return false }
      touched = touch.view
      down = touch.timestamp
      start = touch.location(in: nil)
      return true
    }

    /** the text being edited, with room around it for the selection handles that hang off its ends */
    private func editing(in window: UIWindow?) -> CGRect? {
      guard let window else { return nil }
      func find(_ view: UIView) -> UIView? {
        if view is UITextInput, view.isFirstResponder { return view }
        for sub in view.subviews { if let hit = find(sub) { return hit } }
        return nil
      }
      guard let field = find(window) else { return nil }
      return field.convert(field.bounds, to: nil).insetBy(dx: -24, dy: -24)
    }

    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
      guard let open = swipe?.open else { return false }
      let v = pan.translation(in: nil)
      // a mostly sideways swipe in the direction that makes sense; scrolling stays scrolling
      guard abs(v.x) > abs(v.y) * 1.4, open ? v.x < 0 : v.x > 0 else { return false }
      // a swipe moves at once; a finger held first is selecting text or dragging something
      if ProcessInfo.processInfo.systemUptime - down > 0.25 { return false }
      // the text being edited or selected keeps the finger for its caret and handles
      if editing(in: g.view as? UIWindow)?.contains(start) == true { return false }
      if open { return true }
      var view = touched
      while let current = view {
        if let scroll = current as? UIScrollView,
           scroll.contentSize.width > scroll.bounds.width + 1,
           scroll.contentOffset.x > -scroll.adjustedContentInset.left + 1 {
          return false
        }
        view = current.superview
      }
      return true
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
      true
    }
  }
}

/** How often the open sidebar asks again, so a terminal session that starts or stops shows up. */
private let sidebarPoll: Duration = .seconds(15)

/** The chats, laid out as Settings says (sections, one host at a time, or merged), with search and settings. */
private struct Sidebar: View {
  @Environment(Link.self) private var link
  @AppStorage("sidebarStyle") private var style: SidebarStyle = .sections
  let visible: Bool
  let close: () -> Void
  let newChat: () -> Void
  /** the chat on screen was deleted */
  let cleared: () -> Void
  let settings: () -> Void
  let pair: () -> Void
  @State private var query = ""
  @State private var picked = 0
  @State private var renaming: Listed?
  @State private var newTitle = ""
  @State private var problem: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Wordmark(size: 20)
        Spacer()
        Button(action: newChat) {
          Image(systemName: "square.and.pencil")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .glassEffect(.regular.interactive(), in: .circle)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New chat")
      }
      .padding(.horizontal, 18)

      if style == .switcher {
        HostSwitch()
          .padding(.horizontal, 14)
      }

      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(Color.dim)
        TextField("Search", text: $query)
          .font(.geist(15))
          .autocorrectionDisabled()
        if !query.isEmpty {
          Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color.faint) }
            .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, 12)
      .frame(height: 38)
      .background(Color.white.opacity(0.07), in: .capsule)
      .padding(.horizontal, 16)

      list

      // where you're connected, and the way into settings
      Button(action: settings) {
        HStack(spacing: 12) {
          Image(systemName: link.host?.symbol ?? "antenna.radiowaves.left.and.right")
            .contentTransition(.symbolEffect(.replace))
            .animation(.smooth(duration: 0.3), value: link.host?.id)
            .font(.system(size: 14, weight: .medium))
            .frame(width: 36, height: 36)
            .background(Color.white.opacity(0.08), in: .circle)
          VStack(alignment: .leading, spacing: 2) {
            Text(link.host.map { $0.kind == .cloud ? "Cloud" : $0.name } ?? "spark")
              .font(.geist(15, .medium))
              .lineLimit(1)
              .contentTransition(.opacity)
            if let status {
              Text(status).font(.geist(12)).foregroundStyle(Color.dim)
                .transition(Settle(distance: -4))
            }
          }
          .animation(.smooth(duration: 0.3), value: status)
          .animation(.smooth(duration: 0.3), value: link.host?.id)
          Spacer(minLength: 0)
          Image(systemName: "gearshape")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Color.dim)
        }
        .foregroundStyle(.white)
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Settings")
      .padding(.horizontal, 10)
    }
    .padding(.top, 8)
    .padding(.bottom, 4)
    .frame(maxHeight: .infinity, alignment: .top)
    .sensoryFeedback(.selection, trigger: picked)
    .alert("Rename chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
      TextField("Title", text: $newTitle)
      Button("Cancel", role: .cancel) {}
      Button("Rename") {
        guard let l = renaming else { return }
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != l.session.title else { return }
        Task {
          do { try await link.rename(l.session, on: l.host.id, to: title) } catch { problem = error.localizedDescription }
        }
      }
    }
    .alert("Couldn't change that chat", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(problem ?? "")
    }
    .task(id: "\(visible)-\(link.phase == .online)") {
      guard link.phase == .online else { return }
      if !visible {
        await link.refreshAll()
        return
      }
      while !Task.isCancelled {
        await link.refreshAll()
        try? await Task.sleep(for: sidebarPoll)
      }
    }
  }

  /** said only when something is wrong */
  private var status: String? {
    guard link.phase == .online else { return "Connecting" }
    return link.host?.online == true ? nil : "Offline"
  }

  private func matches(_ s: SessionInfo) -> Bool {
    query.isEmpty || s.title.localizedCaseInsensitiveContains(query) || s.cwd.localizedCaseInsensitiveContains(query)
  }

  /** the cloud first, then each Mac */
  private var orderedHosts: [HostEntry] {
    link.hosts.filter { $0.kind == .cloud } + link.hosts.filter { $0.kind != .cloud }
  }

  @ViewBuilder private var list: some View {
    ScrollView {
      // a plain stack: a lazy one jumps when a row in the middle leaves
      VStack(alignment: .leading, spacing: 2) {
        switch style {
        case .switcher: switcherList
        case .sections: sectionsList
        case .merged: mergedList
        }
      }
      // a fresh list for each layout: a lazy stack otherwise keeps rows drawn for the last one
      .id(style)
      .padding(.horizontal, 6)
      .animation(.smooth(duration: 0.32), value: link.listed.map(\.id))
      // a Mac going offline or coming back: its note, its rows and its dimming all ease over together
      .animation(.smooth(duration: 0.4), value: link.hosts.map { "\($0.id)-\($0.online)" })
    }
    .scrollIndicators(.hidden)
    .refreshable { await link.refreshAll() }
  }

  /** B: the chosen host only */
  @ViewBuilder private var switcherList: some View {
    let host = link.host
    let shown = host.map { h in (link.sessions[h.id] ?? []).filter(matches).map { Listed(host: h, session: $0) } } ?? []
    if let host, !host.online { offline(host) }
    grouped(shown, badges: false)
    if host?.online == true { empty(shown.isEmpty) }
  }

  /** A: a heading for each host, its chats under it */
  @ViewBuilder private var sectionsList: some View {
    let hosts = orderedHosts
    let headed = hosts.count > 1
    ForEach(hosts) { h in
      let shown = (link.sessions[h.id] ?? []).filter(matches).map { Listed(host: h, session: $0) }
      VStack(alignment: .leading, spacing: 2) {
        if headed { heading(h) }
        // the offline note and "No chats yet" trade places in one spot, so the section eases from one
        // height to the other instead of holding both for a moment
        ZStack(alignment: .topLeading) {
          if !h.online { offline(h) }
          // said only once the host has answered, so a refresh never flashes it
          if h.online, shown.isEmpty, link.sessions[h.id] != nil {
            Text(query.isEmpty ? "No chats yet" : "No chats match")
              .font(.geist(13))
              .foregroundStyle(Color.faint)
              .padding(.horizontal, 12)
              .padding(.vertical, 6)
              .transition(Settle(distance: -4))
          }
        }
        ForEach(shown) { row($0, badge: false) }
      }
      .opacity(h.online ? 1 : 0.55)
      .padding(.bottom, 10)
    }
  }

  /** C: everything by date, each row marked with its host */
  @ViewBuilder private var mergedList: some View {
    let shown = link.listed.filter { matches($0.session) }
    ForEach(link.hosts.filter { !$0.online }) { offline($0) }
    grouped(shown, badges: link.hosts.count > 1)
    empty(shown.isEmpty && link.hosts.contains(where: \.online))
  }

  @ViewBuilder private func grouped(_ list: [Listed], badges: Bool) -> some View {
    ForEach(groups(list), id: \.title) { group in
      Text(group.title)
        .font(.geist(12, .medium))
        .foregroundStyle(Color.faint)
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 4)
      ForEach(group.sessions) { row($0, badge: badges) }
    }
  }

  private func heading(_ h: HostEntry) -> some View {
    HStack(spacing: 6) {
      Image(systemName: h.symbol).font(.system(size: 11, weight: .semibold))
      Text(h.kind == .cloud ? "Cloud" : h.name).lineLimit(1)
    }
    .font(.geist(12, .medium))
    .foregroundStyle(h.online && link.phase == .online ? Color.dim : Color.faint)
    .animation(.smooth(duration: 0.3), value: h.online && link.phase == .online)
    .padding(.horizontal, 12)
    .padding(.top, 10)
    .padding(.bottom, 4)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("section-\(h.kind.rawValue)")
  }

  private func row(_ l: Listed, badge: Bool) -> some View {
    Row(session: l.session, badge: badge ? l.host.symbol : nil, selected: link.chat?.host == l.host.id && link.chat?.info.id == l.session.id) {
      picked += 1
      Task { await link.open(l.session, on: l.host.id) }
      close()
    }
    .contextMenu {
      Button("Rename", systemImage: "pencil") {
        newTitle = l.session.title
        renaming = l
      }
      Button("Delete", systemImage: "trash", role: .destructive) { delete(l) }
        .disabled(l.session.running)
    }
  }

  /** no question asked: the row leaves once the menu has closed, so the two don't fight */
  private func delete(_ l: Listed) {
    Task {
      try? await Task.sleep(for: .milliseconds(320))
      if link.chat?.host == l.host.id, link.chat?.info.id == l.session.id { cleared() }
      do { try await link.delete(l.session, on: l.host.id) } catch { problem = error.localizedDescription }
    }
  }

  private func offline(_ h: HostEntry) -> some View {
    Text(link.hosts.count > 1 ? "\(h.name) is offline. Run spark pair on it, or use the cloud." : "\(h.name) is offline. Run spark pair on it.")
      .font(.geist(13))
      .foregroundStyle(Color.dim)
      .padding(.horizontal, style == .sections ? 12 : 18)
      .padding(.vertical, 6)
      .transition(Settle(distance: -4))
  }

  @ViewBuilder private func empty(_ none: Bool) -> some View {
    if none, !link.sessions.isEmpty {
      Text(query.isEmpty ? "No chats yet" : "No chats match")
        .font(.geist(14))
        .foregroundStyle(Color.faint)
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .transition(.opacity)
    }
  }

  private struct Group {
    var title: String
    var sessions: [Listed]
  }

  private func groups(_ list: [Listed]) -> [Group] {
    let cal = Calendar.current
    var g: [String: [Listed]] = [:]
    for l in list.sorted(by: { $0.session.updated > $1.session.updated }) {
      let s = l.session
      let key = s.running ? "Working" : cal.isDateInToday(s.updated) ? "Today" : cal.isDateInYesterday(s.updated) ? "Yesterday" : s.updated > .now.addingTimeInterval(-7 * 86400) ? "This week" : "Earlier"
      g[key, default: []].append(l)
    }
    return ["Working", "Today", "Yesterday", "This week", "Earlier"].compactMap { k in g[k].map { Group(title: k, sessions: $0) } }
  }

  private struct Row: View {
    let session: SessionInfo
    /** the host's symbol, when rows from more than one host share the list */
    let badge: String?
    let selected: Bool
    let tap: () -> Void

    var body: some View {
      Button(action: tap) {
        VStack(alignment: .leading, spacing: 3) {
          Text(session.title)
            .font(.geist(15, selected ? .semibold : .regular))
            .foregroundStyle(.white)
            .lineLimit(1)
          HStack(spacing: 5) {
            if let badge {
              Image(systemName: badge).font(.system(size: 10, weight: .semibold))
            }
            if session.inTerminal {
              Image(systemName: "apple.terminal")
                .font(.system(size: 10, weight: .semibold))
                .accessibilityLabel("Open in a terminal on the Mac")
            }
            Text(session.folder).font(.geistMono(11)).lineLimit(1)
            Text("·")
            Text(Relative.string(session.updated)).font(.geist(12))
          }
          .foregroundStyle(Color.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(selected ? Color.white.opacity(0.09) : .clear, in: .rect(cornerRadius: 14, style: .continuous))
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
    }
  }
}

/**
 * Mac or cloud: one glass track with the chosen host lit, sliding between them. A Mac that goes
 * offline leaves the track, and the others close up over its place.
 */
struct HostSwitch: View {
  @Environment(Link.self) private var link
  @Namespace private var ns

  var body: some View {
    let hosts = link.pickable
    VStack(spacing: 0) {
      if hosts.count > 1 { track(hosts).transition(Settle(distance: 6)) }
    }
    .animation(.spring(duration: 0.4, bounce: 0), value: hosts.map(\.id))
  }

  private func track(_ hosts: [HostEntry]) -> some View {
    HStack(spacing: 0) {
        ForEach(hosts) { h in
          let on = h.id == link.host?.id
          Button {
            withAnimation(.spring(duration: 0.35, bounce: 0.15)) { link.choose(h.id) }
          } label: {
            HStack(spacing: 6) {
              Image(systemName: h.symbol).font(.system(size: 13, weight: .medium))
              Text(h.kind == .cloud ? "Cloud" : h.name).lineLimit(1)
            }
            .font(.geist(14, .medium))
            .foregroundStyle(on ? .white : Color.dim)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background {
              if on {
                Capsule().fill(Color.white.opacity(0.14)).matchedGeometryEffect(id: "lit", in: ns)
              }
            }
            .contentShape(.capsule)
          }
          .buttonStyle(.plain)
          .transition(.opacity.combined(with: .scale(0.92)))
        }
      }
      .padding(3)
      .glassEffect(.regular, in: .capsule)
      .sensoryFeedback(.selection, trigger: link.hostID)
  }
}
