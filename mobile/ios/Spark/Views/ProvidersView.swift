import SwiftUI

/** What the relay can see when a key goes to the cloud, said wherever a key is entered or copied. */
private let keyNotice = "The key is sent through the relay and stored on the server. The relay isn't end-to-end encrypted, so whoever runs it can read the key."

/** The providers cloud chats can use: add, change, delete, or copy one from the Mac. */
struct CloudProvidersView: View {
  @Environment(Link.self) private var link
  @State private var list: [ProviderSummary]?
  @State private var problem: String?
  @State private var editing: ProviderDraft?
  @State private var copying = false
  @State private var deleting: ProviderSummary?

  private var mac: HostEntry? { link.hosts.first { $0.kind == .mac && $0.online } }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        if let list {
          if list.isEmpty {
            Text("The cloud has no providers yet. Add one, or copy one from your Mac.")
              .font(.geist(15))
              .foregroundStyle(Color.dim)
              .padding(.horizontal, 6)
          } else {
            VStack(spacing: 0) {
              ForEach(list) { p in
                Button { editing = ProviderDraft(p) } label: { ProviderRow(provider: p, line: line(p)) }
                  .buttonStyle(.plain)
                  .contextMenu {
                    Button("Delete", systemImage: "trash", role: .destructive) { deleting = p }
                  }
                  .accessibilityIdentifier("provider-\(p.name)")
                if p.id != list.last?.id { Divider().overlay(Color.hairline).padding(.leading, 58) }
              }
            }
            .background(Color.white.opacity(0.05), in: .rect(cornerRadius: 22, style: .continuous))
          }
        } else if problem == nil {
          ProgressView().tint(Color.dim).frame(maxWidth: .infinity).padding(.top, 40)
        }
        if let problem {
          Text(problem).font(.geist(14)).foregroundStyle(Color.dim).padding(.horizontal, 6)
        }
        VStack(spacing: 0) {
          action("Add a provider", symbol: "plus", id: "addProvider") { editing = ProviderDraft() }
          if let mac {
            Divider().overlay(Color.hairline).padding(.leading, 58)
            action("Copy from \(mac.name)…", symbol: "laptopcomputer.and.arrow.down", id: "copyFromMac") { copying = true }
          }
        }
        .background(Color.white.opacity(0.05), in: .rect(cornerRadius: 22, style: .continuous))
        Text("Cloud chats use these. A copy from your Mac is made once: later changes on either side stay on that side. Chats already open keep the settings they started with.")
          .font(.geist(13))
          .foregroundStyle(Color.faint)
          .padding(.horizontal, 6)
      }
      .padding(.horizontal, 16)
      .padding(.top, 8)
      .padding(.bottom, 32)
    }
    .page()
    .navigationTitle("Cloud providers")
    .navigationBarTitleDisplayMode(.inline)
    .refreshable { await load() }
    .task { await load() }
    .animation(.ease, value: list)
    .sheet(item: $editing) { draft in
      ProviderForm(draft: draft, taken: Set((list ?? []).map(\.name))) { list = $0 }
    }
    .sheet(isPresented: $copying) {
      if let mac { CopyFromMacView(mac: mac, cloud: list ?? []) { list = $0 } }
    }
    .confirmationDialog("Delete \(deleting?.name ?? "this provider") from the cloud?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
      Button("Delete", role: .destructive) {
        if let p = deleting { Task { await delete(p) } }
        deleting = nil
      }
    }
  }

  private func line(_ p: ProviderSummary) -> String {
    let models = p.models.count == 1 ? "1 model" : "\(p.models.count) models"
    let key = p.keyHint.map { "key \($0)" } ?? (p.auth == "none" ? "no key" : "key from \(p.keyEnv ?? "a variable")")
    return [models, key].joined(separator: " · ")
  }

  private func action(_ title: String, symbol: String, id: String, _ run: @escaping () -> Void) -> some View {
    Button(action: run) {
      HStack(spacing: 12) {
        Image(systemName: symbol)
          .font(.system(size: 14, weight: .semibold))
          .frame(width: 34, height: 34)
          .background(Color.white.opacity(0.07), in: .rect(cornerRadius: 10, style: .continuous))
        Text(title).font(.geist(16))
        Spacer(minLength: 0)
      }
      .foregroundStyle(.white)
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier(id)
  }

  private func load() async {
    do {
      list = try await link.providers("cloud")
      problem = nil
    } catch {
      problem = error.localizedDescription
    }
  }

  private func delete(_ p: ProviderSummary) async {
    do {
      list = try await link.deleteProvider(p.name)
      problem = nil
    } catch {
      problem = error.localizedDescription
    }
  }
}

private struct ProviderRow: View {
  let provider: ProviderSummary
  let line: String

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "cpu")
        .font(.system(size: 14, weight: .medium))
        .frame(width: 34, height: 34)
        .background(Color.white.opacity(0.07), in: .rect(cornerRadius: 10, style: .continuous))
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(provider.name).font(.geist(16)).lineLimit(1)
          if provider.active {
            Text("Default").font(.geist(11, .medium)).foregroundStyle(Color.dim)
              .padding(.horizontal, 6).padding(.vertical, 1)
              .background(Color.white.opacity(0.08), in: .capsule)
          }
        }
        Text(provider.baseUrl).font(.geistMono(11)).foregroundStyle(Color.dim).lineLimit(1)
        Text(line).font(.geist(12)).foregroundStyle(Color.faint).lineLimit(1)
      }
      Spacer(minLength: 0)
    }
    .foregroundStyle(.white)
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .contentShape(.rect)
  }
}

// MARK: Form

/** A provider being written: the common fields, and every other field as JSON. */
struct ProviderDraft: Identifiable {
  static let protocols = ["openai-chat-completions", "openai-responses", "anthropic-messages"]

  let id = UUID()
  var original: ProviderSummary?
  var name = ""
  var proto = protocols[0]
  var baseURL = ""
  var key = ""
  /** one model per line */
  var models = ""
  var model = ""
  var advanced = "{}"

  init() {}

  init(_ p: ProviderSummary) {
    original = p
    name = p.name
    proto = p.protocol.isEmpty ? Self.protocols[0] : p.protocol
    baseURL = p.baseUrl
    models = p.models.joined(separator: "\n")
    model = p.model ?? ""
    var rest = p.provider
    for k in ["protocol", "base_url", "auth"] { rest[k] = nil }
    advanced = Self.pretty(.object(rest))
  }

  var modelNames: [String] {
    var seen = Set<String>()
    return models.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && seen.insert($0).inserted }
  }

  /**
   * The provider to save. The model list decides which models there are; the JSON keeps their
   * options under model_metadata. A key left empty keeps the saved one.
   */
  func provider() throws -> [String: JSON] {
    let text = advanced.trimmingCharacters(in: .whitespacesAndNewlines)
    guard case .object(var p)? = try? JSONDecoder().decode(JSON.self, from: Data((text.isEmpty ? "{}" : text).utf8)) else {
      throw LinkError("The advanced settings aren't a JSON object.")
    }
    p["protocol"] = .string(proto)
    p["base_url"] = .string(baseURL.trimmingCharacters(in: .whitespacesAndNewlines))
    let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
    if !key.isEmpty {
      p["auth"] = .object(["type": .string("key"), "key": .string(key)])
    } else if let original, original.auth != "none", let auth = original.provider["auth"] {
      p["auth"] = auth
    } else {
      p["auth"] = .object(["type": .string("none")])
    }
    var options: [String: JSON] = [:]
    if case .object(let o)? = p["model_metadata"] { options = o }
    let names = modelNames
    p["model_metadata"] = names.isEmpty ? nil : .object(Dictionary(uniqueKeysWithValues: names.map { ($0, options[$0] ?? .object([:])) }))
    return p
  }

  static func pretty(_ value: JSON) -> String {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return (try? e.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
  }
}

private struct ProviderForm: View {
  @Environment(Link.self) private var link
  @Environment(\.dismiss) private var dismiss
  @State var draft: ProviderDraft
  /** names already on the cloud, which a new provider can't take */
  let taken: Set<String>
  let saved: ([ProviderSummary]) -> Void
  @State private var saving = false
  @State private var problem: String?
  @State private var showAdvanced = false

  private var editing: Bool { draft.original != nil }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Name", text: $draft.name)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .disabled(editing)
            .accessibilityIdentifier("providerName")
          Picker("Protocol", selection: $draft.proto) {
            ForEach(ProviderDraft.protocols, id: \.self) { Text($0).tag($0) }
          }
          TextField("Base URL", text: $draft.baseURL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .accessibilityIdentifier("providerURL")
        }
        Section {
          SecureField(keyPrompt, text: $draft.key)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier("providerKey")
        } header: {
          Text("API key")
        } footer: {
          Text(keyNotice)
        }
        Section {
          TextEditor(text: $draft.models)
            .font(.geistMono(13))
            .frame(minHeight: 88)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier("providerModels")
          if !draft.modelNames.isEmpty {
            Picker("Default model", selection: $draft.model) {
              Text("None").tag("")
              ForEach(draft.modelNames, id: \.self) { Text($0).tag($0) }
            }
          }
        } header: {
          Text("Models")
        } footer: {
          Text("One model ID per line.")
        }
        Section {
          DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
            TextEditor(text: $draft.advanced)
              .font(.geistMono(12))
              .frame(minHeight: 180)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
          }
        } footer: {
          Text("Every other provider field as JSON, such as headers, timeouts, and each model's options under model_metadata. The model list above decides which models stay.")
        }
        if let problem {
          Section { Text(problem).foregroundStyle(Color(red: 1, green: 0.42, blue: 0.4)) }
        }
      }
      .scrollContentBackground(.hidden)
      .page()
      .navigationTitle(editing ? draft.name : "New provider")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Cancel", systemImage: "xmark") { dismiss() }
        }
        ToolbarItem(placement: .topBarTrailing) {
          if saving {
            ProgressView()
          } else {
            Button("Save", systemImage: "checkmark") { save() }
              .disabled(draft.name.isEmpty || draft.baseURL.isEmpty)
              .accessibilityIdentifier("saveProvider")
          }
        }
      }
    }
    .presentationBackground(Color.page)
    .interactiveDismissDisabled(saving)
  }

  private var keyPrompt: String {
    if let hint = draft.original?.keyHint { return "Saved key \(hint); empty keeps it" }
    if let env = draft.original?.keyEnv { return "Read from \(env); empty keeps it" }
    return "Empty for none"
  }

  private func save() {
    let name = draft.name.trimmingCharacters(in: .whitespaces)
    if !editing, taken.contains(name) {
      problem = "The cloud already has a provider named \(name)."
      return
    }
    let provider: [String: JSON]
    do {
      provider = try draft.provider()
    } catch {
      problem = error.localizedDescription
      return
    }
    saving = true
    Task {
      defer { saving = false }
      do {
        saved(try await link.putProvider(name, provider, model: draft.model))
        dismiss()
      } catch {
        problem = error.localizedDescription
      }
    }
  }
}

// MARK: Copy from the Mac

private struct CopyFromMacView: View {
  @Environment(Link.self) private var link
  @Environment(\.dismiss) private var dismiss
  let mac: HostEntry
  let cloud: [ProviderSummary]
  let done: ([ProviderSummary]) -> Void
  @State private var list: [ProviderSummary]?
  @State private var problem: String?
  @State private var busy: String?
  @State private var conflict: ProviderSummary?
  @State private var renaming: ProviderSummary?
  @State private var newName = ""

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          if let list {
            if list.isEmpty {
              Text("\(mac.name) has no providers in its spark settings.")
                .font(.geist(15)).foregroundStyle(Color.dim).padding(.horizontal, 6)
            } else {
              VStack(spacing: 0) {
                ForEach(list) { p in
                  Button { pick(p) } label: {
                    HStack {
                      ProviderRow(provider: p, line: line(p))
                      if busy == p.name { ProgressView().padding(.trailing, 14) }
                    }
                  }
                  .buttonStyle(.plain)
                  .disabled(busy != nil)
                  .accessibilityIdentifier("macProvider-\(p.name)")
                  if p.id != list.last?.id { Divider().overlay(Color.hairline).padding(.leading, 58) }
                }
              }
              .background(Color.white.opacity(0.05), in: .rect(cornerRadius: 22, style: .continuous))
            }
          } else if problem == nil {
            ProgressView().tint(Color.dim).frame(maxWidth: .infinity).padding(.top, 40)
          }
          if let problem {
            Text(problem).font(.geist(14)).foregroundStyle(Color.dim).padding(.horizontal, 6)
          }
          Text("Tap one to copy it: its address, key, models, and every other setting. \(keyNotice) The copy is made once; later changes on \(mac.name) stay there.")
            .font(.geist(13))
            .foregroundStyle(Color.faint)
            .padding(.horizontal, 6)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 32)
      }
      .page()
      .navigationTitle("Copy from \(mac.name)")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Close", systemImage: "xmark") { dismiss() }
        }
      }
      .task {
        do { list = try await link.providers(mac.id) } catch { problem = error.localizedDescription }
      }
      .confirmationDialog("The cloud already has \(conflict?.name ?? "one by that name").", isPresented: Binding(get: { conflict != nil }, set: { if !$0 { conflict = nil } }), titleVisibility: .visible) {
        Button("Replace it", role: .destructive) {
          if let p = conflict { copy(p, as: p.name) }
          conflict = nil
        }
        Button("Copy with another name") {
          if let p = conflict {
            newName = "\(p.name)-mac"
            renaming = p
          }
          conflict = nil
        }
      }
      .alert("Name in the cloud", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
        TextField("Name", text: $newName)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        Button("Copy") {
          if let p = renaming { pick(p, as: newName.trimmingCharacters(in: .whitespaces)) }
          renaming = nil
        }
        Button("Cancel", role: .cancel) { renaming = nil }
      }
    }
    .presentationBackground(Color.page)
  }

  /** what the copy takes from the Mac besides the provider itself */
  private func line(_ p: ProviderSummary) -> String {
    var parts: [String] = []
    switch p.auth {
    case "key": parts.append("key \(p.keyHint ?? "…")")
    case "bearer": parts.append("copies the key from \(p.keyEnv ?? "a variable")")
    default: parts.append("no key")
    }
    if !p.headerEnv.isEmpty { parts.append("copies \(p.headerEnv.joined(separator: ", "))") }
    return parts.joined(separator: " · ")
  }

  private func pick(_ p: ProviderSummary, as name: String? = nil) {
    let target = name ?? p.name
    if cloud.contains(where: { $0.name == target }) {
      if name == nil { conflict = p } else { problem = "The cloud already has \(target) too." }
      return
    }
    copy(p, as: target)
  }

  private func copy(_ p: ProviderSummary, as name: String) {
    busy = p.name
    problem = nil
    Task {
      defer { busy = nil }
      do {
        done(try await link.copyProvider(p.name, from: mac.id, as: name))
        dismiss()
      } catch {
        problem = error.localizedDescription
      }
    }
  }
}
