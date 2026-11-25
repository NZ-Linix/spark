import SwiftUI

struct ChatGPTAccountsView: View {
  @Environment(Link.self) private var link
  let mac: HostEntry
  @State private var accounts: [ProviderSummary]?
  @State private var adding = false
  @State private var label = ""
  @State private var removing: ProviderSummary?
  @State private var progress: String?
  @State private var message: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Text("Use your ChatGPT plan in Spark chats on \(mac.name). Sign-in opens in that Mac’s browser, and your credentials stay on the Mac.")
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
          Text("Continue with ChatGPT").font(.geist(16, .medium))
            .foregroundStyle(Color.black)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .disabled(progress != nil || accounts == nil)
        .accessibilityIdentifier("chatGPTContinue")
        if let progress {
          HStack(spacing: 10) {
            ProgressView().tint(Color.dim)
            Text(progress)
          }
          .font(.geist(14)).foregroundStyle(Color.dim)
        }
        if let message { Text(message).font(.geist(14)).foregroundStyle(Color.dim) }
        if accounts != nil {
          SwiftUI.Link(destination: URL(string: "https://chatgpt.com/settings/usage")!) {
            Text("Manage ChatGPT usage").font(.geist(14))
          }
        }
      }
      .frame(maxWidth: 520, alignment: .leading)
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .frame(maxWidth: .infinity)
    }
    .page()
    .navigationTitle("ChatGPT Plans")
    .navigationBarTitleDisplayMode(.inline)
    .task { await load() }
    .refreshable { await load() }
    .alert("Add a ChatGPT account", isPresented: $adding) {
      TextField("Account label (optional)", text: $label)
      Button("Cancel", role: .cancel) {}
      Button("Continue with ChatGPT") { Task { await change("connect", label.trimmingCharacters(in: .whitespacesAndNewlines)) } }
    } message: {
      Text("Use a label like Work or Personal to distinguish this account in the model picker.")
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
      accounts = try await link.chatGPTAccounts(mac.id)
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
      let result = try await link.changeChatGPTAccount(mac.id, action: action, value: value)
      accounts = result.accounts
      message = result.warning ?? (action == "remove" ? "Account disconnected." : "Connected. Choose this account in the model picker for chats on \(mac.name).")
    } catch {
      message = error.localizedDescription
    }
  }
}
