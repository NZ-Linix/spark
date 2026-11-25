import SwiftUI

/** A subscription a paired Mac can sign in to, so its chats run on the plan instead of an API key. */
enum SubscriptionPlan: String, CaseIterable, Identifiable {
  case chatgpt
  case claude
  case antigravity

  var id: String { rawValue }

  /** what the accounts are called in the provider and model pickers */
  var product: String {
    switch self {
    case .chatgpt: "Codex"
    case .claude: "Claude"
    case .antigravity: "Antigravity"
    }
  }

  var title: String {
    switch self {
    case .chatgpt: "ChatGPT Plans"
    case .claude: "Claude Subscriptions"
    case .antigravity: "Antigravity (Google AI)"
    }
  }

  var continueLabel: String {
    switch self {
    case .chatgpt: "Continue with ChatGPT"
    case .claude: "Continue with Claude"
    case .antigravity: "Continue with Google"
    }
  }

  var symbol: String {
    switch self {
    case .chatgpt: "person.crop.circle"
    case .claude: "sparkle"
    case .antigravity: "globe"
    }
  }

  var summary: String {
    switch self {
    case .chatgpt: "Use your ChatGPT plan"
    case .claude: "Use your Claude Pro or Max subscription"
    case .antigravity: "Use your Antigravity (Google AI) subscription"
    }
  }

  var usage: (label: String, url: URL) {
    switch self {
    case .chatgpt: ("Manage ChatGPT usage", URL(string: "https://chatgpt.com/settings/usage")!)
    case .claude: ("Manage Claude usage", URL(string: "https://claude.ai/settings/usage")!)
    case .antigravity: ("About Antigravity", URL(string: "https://antigravity.google/")!)
    }
  }
}

struct SubscriptionAccountsView: View {
  @Environment(Link.self) private var link
  let mac: HostEntry
  let plan: SubscriptionPlan
  @State private var accounts: [ProviderSummary]?
  @State private var adding = false
  @State private var label = ""
  @State private var removing: ProviderSummary?
  @State private var progress: String?
  @State private var message: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Text("\(plan.summary) in Spark chats on \(mac.name). Sign-in opens in that Mac’s browser, and your credentials stay on the Mac. Spark uses its own prompt and tools with the plan.")
          .font(.geist(15)).foregroundStyle(Color.dim)
        if accounts == nil && message == nil {
          ProgressView().tint(Color.dim).frame(maxWidth: .infinity)
        } else if let accounts, accounts.isEmpty {
          Text("No accounts connected").font(.geist(15, .medium))
        } else if let accounts {
          VStack(spacing: 0) {
            ForEach(accounts) { account in
              HStack(spacing: 12) {
                Text(account.title).font(.geist(16))
                Spacer()
                Menu {
                  Button("Sign in again") { Task { await change("reconnect", account.name) } }
                  Button("Disconnect", role: .destructive) { removing = account }
                } label: {
                  Image(systemName: "ellipsis").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Manage \(account.title)")
              }
              .padding(.leading, 14).padding(.trailing, 6)
              if account.id != accounts.last?.id { Divider().overlay(Color.hairline).padding(.leading, 14) }
            }
          }
          .background(Color.white.opacity(0.05), in: .rect(cornerRadius: 22))
          .disabled(progress != nil)
        }
        Button {
          label = ""
          adding = true
        } label: {
          Text(plan.continueLabel).font(.geist(16, .medium))
            .foregroundStyle(Color.black)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .disabled(progress != nil || accounts == nil)
        .accessibilityIdentifier("planContinue")
        if let progress {
          HStack(spacing: 10) {
            ProgressView().tint(Color.dim)
            Text(progress)
          }
          .font(.geist(14)).foregroundStyle(Color.dim)
        }
        if let message { Text(message).font(.geist(14)).foregroundStyle(Color.dim) }
        if accounts != nil {
          SwiftUI.Link(destination: plan.usage.url) {
            Text(plan.usage.label).font(.geist(14))
          }
        }
      }
      .frame(maxWidth: 520, alignment: .leading)
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .frame(maxWidth: .infinity)
    }
    .page()
    .navigationTitle(plan.title)
    .navigationBarTitleDisplayMode(.inline)
    .task { await load() }
    .refreshable { await load() }
    .alert("New \(plan.product) account", isPresented: $adding) {
      TextField("Account label (optional)", text: $label)
      Button("Cancel", role: .cancel) {}
      Button(plan.continueLabel) { Task { await change("connect", label.trimmingCharacters(in: .whitespacesAndNewlines)) } }
    } message: {
      Text("Use a label like Work or Personal to tell accounts apart in the model picker, as in \(plan.product) (Work).")
    }
    .confirmationDialog("Disconnect \(removing?.title ?? "this account")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
      Button("Disconnect", role: .destructive) {
        if let account = removing { Task { await change("remove", account.name) } }
        removing = nil
      }
    } message: {
      Text("Chats on this Mac will no longer be able to use this account.")
    }
  }

  private func load() async {
    do {
      accounts = try await link.planAccounts(mac.id, plan: plan)
      message = nil
    } catch {
      message = error.localizedDescription
    }
  }

  private func change(_ action: String, _ value: String) async {
    guard progress == nil else { return }
    message = nil
    progress = action == "remove" ? "Disconnecting…" : "Finish signing in on \(mac.name)."
    defer { progress = nil }
    do {
      let result = try await link.changePlanAccount(mac.id, plan: plan, action: action, value: value)
      accounts = result.accounts
      message = result.warning ?? (action == "remove" ? "Account disconnected." : "Connected. Choose this account in the model picker for chats on \(mac.name).")
    } catch {
      message = error.localizedDescription
    }
  }
}
