import SwiftUI

/** What any screen can ask of the shell around it. */
struct ShellActions {
  var menu: () -> Void = {}
  var newChat: () -> Void = {}
}

extension EnvironmentValues {
  @Entry var shell = ShellActions()
}

/**
 * The app once paired: the open chat fills the screen, and the sidebar of chats slides in from the
 * left. Swipe right anywhere to open it, left to close it; it follows the finger and settles by speed.
 */
struct Shell: View {
  @Environment(Link.self) private var link
  @State private var open = false
  @State private var drag: CGFloat = 0
  @State private var tracking: Bool?
  @State private var showSettings = false
  @State private var showPair = false
  @State private var opened = 0
  /** bumped to show the folder picker for a new chat */
  @State private var newChat = 0

  var body: some View {
    GeometryReader { geo in
      let width = min(geo.size.width * 0.84, 340)
      let progress = max(0, min(1, ((open ? width : 0) + drag) / width))
      ZStack(alignment: .leading) {
        Sidebar(visible: open, close: { set(false) }, newChat: startNew, settings: { showSettings = true }, pair: { showPair = true })
          .frame(width: width)
          .offset(x: (progress - 1) * width * 0.35)
          .opacity(0.4 + progress * 0.6)
          .accessibilityHidden(progress < 0.5)

        main
          .frame(width: geo.size.width)
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
      .simultaneousGesture(swipe(width))
    }
    .page()
    .environment(\.shell, ShellActions(menu: { set(true) }, newChat: startNew))
    .sensoryFeedback(.impact(weight: .light), trigger: opened)
    .sheet(isPresented: $showSettings) { SettingsView(pair: { showSettings = false; showPair = true }) }
    .sheet(isPresented: $showPair) { PairView() }
  }

  @ViewBuilder private var main: some View {
    NavigationStack {
      if let chat = link.chat {
        ChatView(chat: chat).id(chat.key)
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

  private func swipe(_ width: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: 14, coordinateSpace: .global)
      .onChanged { v in
        if tracking == nil {
          // only a mostly sideways swipe in the direction that makes sense; scrolling stays scrolling
          let dx = v.translation.width
          let dy = v.translation.height
          tracking = abs(dx) > abs(dy) * 1.4 && (open ? dx < 0 : dx > 0)
          if tracking == true, !open {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
          }
        }
        guard tracking == true else { return }
        let dx = v.translation.width
        drag = open ? min(0, dx) : max(0, dx)
      }
      .onEnded { v in
        defer { tracking = nil }
        guard tracking == true else { return }
        let projected = (open ? width : 0) + v.predictedEndTranslation.width
        set(projected > width / 2)
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
  let settings: () -> Void
  let pair: () -> Void
  @State private var query = ""
  @State private var picked = 0

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
            .font(.system(size: 14, weight: .medium))
            .frame(width: 36, height: 36)
            .background(Color.white.opacity(0.08), in: .circle)
          VStack(alignment: .leading, spacing: 2) {
            Text(link.host.map { $0.kind == .cloud ? "Cloud" : $0.name } ?? "spark")
              .font(.geist(15, .medium))
              .lineLimit(1)
            HStack(spacing: 5) {
              LiveDot(on: (link.host?.online ?? false) && link.phase == .online)
              Text(status).font(.geist(12)).foregroundStyle(Color.dim)
            }
          }
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

  private var status: String {
    guard link.phase == .online else { return "Connecting" }
    return link.host?.online == true ? "Online" : "Offline"
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
      LazyVStack(alignment: .leading, spacing: 2, pinnedViews: []) {
        switch style {
        case .switcher: switcherList
        case .sections: sectionsList
        case .merged: mergedList
        }
      }
      // a fresh list for each layout: a lazy stack otherwise keeps rows drawn for the last one
      .id(style)
      .padding(.horizontal, 6)
      .animation(.ease, value: link.listed.map(\.id))
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
        if !h.online { offline(h) }
        ForEach(shown) { row($0, badge: false) }
        if h.online, shown.isEmpty, !link.loadingSessions {
          Text(query.isEmpty ? "No chats yet" : "No chats match")
            .font(.geist(13))
            .foregroundStyle(Color.faint)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
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
      LiveDot(on: h.online && link.phase == .online)
    }
    .font(.geist(12, .medium))
    .foregroundStyle(Color.dim)
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
  }

  private func offline(_ h: HostEntry) -> some View {
    Text(link.hosts.count > 1 ? "\(h.name) is offline. Run spark pair on it, or use the cloud." : "\(h.name) is offline. Run spark pair on it.")
      .font(.geist(13))
      .foregroundStyle(Color.dim)
      .padding(.horizontal, style == .sections ? 12 : 18)
      .padding(.vertical, 6)
  }

  @ViewBuilder private func empty(_ none: Bool) -> some View {
    if none, !link.loadingSessions {
      Text(query.isEmpty ? "No chats yet" : "No chats match")
        .font(.geist(14))
        .foregroundStyle(Color.faint)
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
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
            if session.running { LiveDot() }
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

/** Mac or cloud: one glass track with the chosen host lit, sliding between them. */
struct HostSwitch: View {
  @Environment(Link.self) private var link
  @Namespace private var ns

  var body: some View {
    if link.hosts.count > 1 {
      HStack(spacing: 0) {
        ForEach(link.hosts) { h in
          let on = h.id == link.host?.id
          Button {
            withAnimation(.spring(duration: 0.35, bounce: 0.15)) { link.hostID = h.id }
          } label: {
            HStack(spacing: 6) {
              Image(systemName: h.symbol).font(.system(size: 13, weight: .medium))
              Text(h.kind == .cloud ? "Cloud" : h.name).lineLimit(1)
              if !h.online { Circle().fill(Color.faint).frame(width: 5, height: 5) }
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
        }
      }
      .padding(3)
      .glassEffect(.regular, in: .capsule)
      .sensoryFeedback(.selection, trigger: link.hostID)
    }
  }
}
