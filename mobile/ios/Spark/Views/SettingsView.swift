import SwiftUI

/** How the sidebar lays out chats from more than one host. */
enum SidebarStyle: String, CaseIterable, Identifiable {
  /** one list, a small section for each host */
  case sections
  /** one host at a time, with a switch between them */
  case switcher
  /** one list by date, each row marked with its host */
  case merged

  var id: String { rawValue }
  var name: String {
    switch self {
    case .sections: "Sections"
    case .switcher: "Switch"
    case .merged: "Merged"
    }
  }
  var detail: String {
    switch self {
    case .sections: "Cloud and Mac chats in one list, each under its own heading."
    case .switcher: "One computer at a time, with a switch at the top."
    case .merged: "Every chat in one list by date, with a small mark for where it runs."
    }
  }
}

/** Where this iPhone is connected, the computers it can run on, and the way out. */
struct SettingsView: View {
  @Environment(Link.self) private var link
  @Environment(\.dismiss) private var dismiss
  let pair: () -> Void
  @State private var confirmLeave = false
  @State private var unpairing: HostEntry?
  @AppStorage("sidebarStyle") private var style: SidebarStyle = .sections

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 28) {
          connection
          hosts
          subscriptions
          sidebar
          if link.hosts.contains(where: { $0.kind == .cloud }) { library }
          about
          Button("Forget all pairings", role: .destructive) { confirmLeave = true }
            .font(.geist(15, .medium))
            .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.4))
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 32)
      }
      .page()
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done", systemImage: "checkmark") { dismiss() }
        }
      }
      .confirmationDialog("Forget every pairing on this iPhone? You'll need to run spark pair again.", isPresented: $confirmLeave, titleVisibility: .visible) {
        Button("Forget", role: .destructive) {
          dismiss()
          link.leave()
        }
      }
      .confirmationDialog("Unpair \(unpairing?.name ?? "this Mac")?", isPresented: Binding(get: { unpairing != nil }, set: { if !$0 { unpairing = nil } }), titleVisibility: .visible) {
        Button("Unpair", role: .destructive) {
          if let h = unpairing { Task { await link.unpair(h) } }
          unpairing = nil
        }
      } message: {
        Text("Run spark pair on it to pair again.")
      }
    }
    .presentationBackground(Color.page)
    .animation(.ease, value: link.hosts)
  }

  private var connection: some View {
    HStack(spacing: 14) {
      ZStack {
        Circle().fill(Color.white.opacity(0.06))
        Image(systemName: link.phase == .online ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
          .font(.system(size: 16, weight: .medium))
          .foregroundStyle(link.phase == .online ? Color.white : Color.dim)
      }
      .frame(width: 44, height: 44)
      VStack(alignment: .leading, spacing: 3) {
        Text(status).font(.geist(17, .medium))
        Text(link.relay?.host() ?? "No relay").font(.geistMono(12)).foregroundStyle(Color.dim).lineLimit(1)
      }
      Spacer(minLength: 0)
    }
    .padding(14)
    .background(Color.white.opacity(0.05), in: .rect(cornerRadius: 22, style: .continuous))
  }

  private var hosts: some View {
    VStack(alignment: .leading, spacing: 8) {
      Caption("Computers")
      VStack(spacing: 0) {
        ForEach(link.hosts) { h in
          HStack(spacing: 12) {
            Image(systemName: h.symbol)
              .font(.system(size: 14, weight: .medium))
              .frame(width: 34, height: 34)
              .background(Color.white.opacity(0.07), in: .rect(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
              Text(h.kind == .cloud ? "Cloud" : h.name).font(.geist(16))
              if !h.online { Text("Offline").font(.geist(12)).foregroundStyle(Color.faint) }
            }
            Spacer(minLength: 0)
            if h.kind == .mac {
              Menu {
                Button("Unpair", systemImage: "xmark", role: .destructive) { unpairing = h }
              } label: {
                Image(systemName: "ellipsis")
                  .font(.system(size: 14, weight: .semibold))
                  .foregroundStyle(Color.dim)
                  .frame(width: 32, height: 32)
                  .contentShape(.rect)
              }
              .accessibilityLabel("More for \(h.name)")
            }
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 10)
          Divider().overlay(Color.hairline).padding(.leading, 58)
        }
        Button(action: pair) {
          HStack(spacing: 12) {
            Image(systemName: "plus")
              .font(.system(size: 14, weight: .semibold))
              .frame(width: 34, height: 34)
              .background(Color.white.opacity(0.07), in: .rect(cornerRadius: 10, style: .continuous))
            Text("Pair a Mac").font(.geist(16))
            Spacer(minLength: 0)
          }
          .foregroundStyle(.white)
          .padding(.horizontal, 12)
          .padding(.vertical, 10)
          .contentShape(.rect)
        }
        .buttonStyle(.plain)
      }
      .background(Color.white.opacity(0.05), in: .rect(cornerRadius: 22, style: .continuous))
      Text("Run spark pair on a Mac to add it. The cloud keeps working while your Mac sleeps.")
        .font(.geist(13))
        .foregroundStyle(Color.faint)
        .padding(.horizontal, 6)
    }
  }

  private var subscriptions: some View {
    VStack(alignment: .leading, spacing: 8) {
      Caption("Subscription accounts")
      VStack(spacing: 0) {
        ForEach(link.hosts.filter { $0.kind == .mac }) { mac in
          ForEach(SubscriptionPlan.allCases) { plan in
            providersLink("\(plan.title) on \(mac.name)", symbol: plan.symbol, id: "plan-\(plan.rawValue)-\(mac.id)") {
              SubscriptionAccountsView(mac: mac, plan: plan)
            }
            .disabled(!mac.online)
            .opacity(mac.online ? 1 : 0.5)
          }
        }
      }
      .background(Color.white.opacity(0.05), in: .rect(cornerRadius: 22, style: .continuous))
      Text("ChatGPT, Claude and Antigravity subscriptions work in chats on your paired Mac. Sign-in opens in its browser. Accounts are not shared with Cloud.")
        .font(.geist(13))
        .foregroundStyle(Color.faint)
        .padding(.horizontal, 6)
    }
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 8) {
      Caption("Sidebar")
      Picker("Sidebar", selection: $style) {
        ForEach(SidebarStyle.allCases) { Text($0.name).tag($0) }
      }
      .pickerStyle(.segmented)
      .accessibilityIdentifier("sidebarStyle")
      Text(style.detail)
        .font(.geist(13))
        .foregroundStyle(Color.faint)
        .padding(.horizontal, 6)
        .contentTransition(.opacity)
        .animation(.ease, value: style)
    }
  }

  private func providersLink<Destination: View>(_ title: String, symbol: String, id: String, @ViewBuilder _ destination: @escaping () -> Destination) -> some View {
    NavigationLink(destination: destination) {
      HStack(spacing: 12) {
        Image(systemName: symbol)
          .font(.system(size: 14, weight: .medium))
          .frame(width: 34, height: 34)
          .background(Color.white.opacity(0.07), in: .rect(cornerRadius: 10, style: .continuous))
        Text(title).font(.geist(16))
        Spacer(minLength: 0)
        Image(systemName: "chevron.right")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(Color.faint)
      }
      .foregroundStyle(.white)
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier(id)
  }

  private var library: some View {
    VStack(alignment: .leading, spacing: 8) {
      Caption("Library")
      VStack(spacing: 0) {
        providersLink("Providers", symbol: "server.rack", id: "cloudProviders") { CloudProvidersView() }
        Divider().overlay(Color.hairline).padding(.leading, 58)
        providersLink("Prompts", symbol: "text.quote", id: "prompts") { PromptsView() }
        Divider().overlay(Color.hairline).padding(.leading, 58)
        providersLink("MCP Servers", symbol: "point.3.connected.trianglepath.dotted", id: "mcpServers") { McpServersView() }
      }
      .background(Color.white.opacity(0.05), in: .rect(cornerRadius: 22, style: .continuous))
      Text("One set of providers, prompts and MCP servers for the cloud and every paired Mac. A new chat can start with any prompt instead of spark's own.")
        .font(.geist(13))
        .foregroundStyle(Color.faint)
        .padding(.horizontal, 6)
    }
  }

  private var about: some View {
    VStack(alignment: .leading, spacing: 8) {
      Caption("About")
      HStack {
        Wordmark(size: 15)
        Spacer()
        Text(version).font(.geistMono(13)).foregroundStyle(Color.dim)
      }
      .padding(.horizontal, 16)
      .frame(height: 52)
      .background(Color.white.opacity(0.05), in: .rect(cornerRadius: 22, style: .continuous))
    }
  }

  private var version: String {
    let info = Bundle.main.infoDictionary
    let v = info?["CFBundleShortVersionString"] as? String ?? "–"
    let b = info?["CFBundleVersion"] as? String
    return b.map { "\(v) (\($0))" } ?? v
  }

  private var status: String {
    switch link.phase {
    case .online: "Connected"
    case .connecting: "Connecting"
    case .offline: "Reconnecting"
    case .none: "Not set up"
    }
  }
}

struct Caption: View {
  let text: String
  init(_ text: String) { self.text = text }
  var body: some View {
    Text(text)
      .font(.geist(13, .medium))
      .foregroundStyle(Color.faint)
      .padding(.horizontal, 6)
  }
}
