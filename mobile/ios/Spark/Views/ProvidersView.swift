import SwiftUI

/** What the relay can see when a key goes to the library, said wherever a key is entered. */
private func keyNotice(cloud: Bool) -> String {
  "The key is sent through the relay, stored on the server, and copied to each of your Macs. The relay isn't end-to-end encrypted, so whoever runs it can read the key."
}

/** The providers every chat shares, on the cloud and each Mac: add, change, rename, or delete one. */
struct CloudProvidersView: View {
  var body: some View { ProvidersView(host: "cloud", hostName: "the library") }
}

/** One host's providers: the cloud's, or a Mac's own spark settings. */
struct ProvidersView: View {
  @Environment(Link.self) private var link
  let host: String
  let hostName: String
  @State private var list: [ProviderSummary]?
  @State private var problem: String?
  @State private var editing: ProviderDraft?
  @State private var deleting: ProviderSummary?

  private var cloud: Bool { host == "cloud" }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        if let list {
          if list.isEmpty {
            Text("There are no providers yet. Add one here, or with spark provider or /provider on a Mac.")
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
        }
        .background(Color.white.opacity(0.05), in: .rect(cornerRadius: 22, style: .continuous))
        Text("The cloud and every paired Mac use these providers. A change made here, or in spark on a Mac, reaches all of them. Chats already open keep the settings they started with.")
          .font(.geist(13))
          .foregroundStyle(Color.faint)
          .padding(.horizontal, 6)
      }
      .padding(.horizontal, 16)
      .padding(.top, 8)
      .padding(.bottom, 32)
    }
    .page()
    .navigationTitle("Providers")
    .navigationBarTitleDisplayMode(.inline)
    .refreshable { await load() }
    .task { await load() }
    .animation(.ease, value: list)
    .sheet(item: $editing) { draft in
      ProviderForm(draft: draft, host: host, taken: Set((list ?? []).map(\.name))) { list = $0 }
    }
    .confirmationDialog("Delete \(deleting?.title ?? "this provider") everywhere?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
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
      list = try await link.providers(host)
      problem = nil
    } catch {
      problem = error.localizedDescription
    }
  }

  private func delete(_ p: ProviderSummary) async {
    do {
      list = try await link.deleteProvider(p.name, on: host)
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
          Text(provider.title).font(.geist(16)).lineLimit(1)
          if provider.displayName != nil {
            Text(provider.name).font(.geistMono(11)).foregroundStyle(Color.faint).lineLimit(1)
          }
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

// MARK: Drafts

/** One model being written. Fields the form doesn't show, such as request fields, stay in `rest`. */
struct ModelDraft: Identifiable, Hashable {
  static let commonEfforts = ["minimal", "low", "medium", "high", "xhigh", "max"]

  let id = UUID()
  var modelID = ""
  var displayName = ""
  var context = ""
  var maxOutput = ""
  var tools = true
  var vision = false
  var efforts: [String] = []
  /** the saved levels, whose request fields a kept level keeps */
  var savedEfforts: [String: JSON] = [:]
  var rest: [String: JSON] = [:]

  init() {}

  init(id: String, _ meta: [String: JSON]) {
    modelID = id
    var m = meta
    if case .string(let s)? = m.removeValue(forKey: "display_name") { displayName = s }
    if let n = m.removeValue(forKey: "context_window")?.int { context = String(n) }
    if let n = m.removeValue(forKey: "max_output_tokens")?.int { maxOutput = String(n) }
    if case .bool(let b)? = m.removeValue(forKey: "supports_tool_use") { tools = b }
    if case .bool(let b)? = m.removeValue(forKey: "supports_vision") { vision = b }
    if case .object(let levels)? = m.removeValue(forKey: "reasoning_efforts") {
      savedEfforts = levels
      // JSON objects lose their order; list the common levels in their usual order first
      efforts = levels.keys.sorted { Self.rank($0) < Self.rank($1) }
    }
    rest = m
  }

  static func rank(_ level: String) -> Int { commonEfforts.firstIndex(of: level) ?? commonEfforts.count }

  var title: String { displayName.isEmpty ? modelID : displayName }

  func metadata() -> [String: JSON] {
    var m = rest
    if !displayName.trimmed.isEmpty { m["display_name"] = .string(displayName.trimmed) }
    if let n = Self.tokens(context) { m["context_window"] = .number(Double(n)) }
    if let n = Self.tokens(maxOutput) { m["max_output_tokens"] = .number(Double(n)) }
    m["supports_tool_use"] = .bool(tools)
    if vision { m["supports_vision"] = .bool(true) }
    if !efforts.isEmpty {
      m["reasoning_efforts"] = .object(Dictionary(uniqueKeysWithValues: efforts.map { ($0, savedEfforts[$0] ?? .object(["reasoning_effort": .string($0)])) }))
    }
    return m
  }

  /** "200k", "1m", "128,000" and "128000" all read as a count */
  static func tokens(_ text: String) -> Int? {
    let t = text.lowercased().filter { !" ,_".contains($0) }
    guard !t.isEmpty else { return nil }
    if let n = Int(t) { return n }
    let unit = t.hasSuffix("k") ? 1000 : t.hasSuffix("m") ? 1_000_000 : 0
    guard unit > 0, let n = Double(t.dropLast()) else { return nil }
    return Int(n * Double(unit))
  }
}

/** A provider being written. Fields the form doesn't show, such as headers, stay as they were. */
struct ProviderDraft: Identifiable {
  static let protocols = ["openai-chat-completions", "openai-responses", "anthropic-messages"]
  enum KeyMode: String, CaseIterable { case none, key, env }

  let id = UUID()
  var original: ProviderSummary?
  var displayName = ""
  var name = ""
  var proto = protocols[0]
  var baseURL = ""
  var keyMode = KeyMode.key
  var key = ""
  var keyEnv = ""
  var models: [ModelDraft] = []
  var model = ""
  var connect = ""
  var firstResponse = ""
  var stall = ""

  init() {}

  init(_ p: ProviderSummary) {
    original = p
    name = p.name
    displayName = p.displayName ?? ""
    proto = p.protocol.isEmpty ? Self.protocols[0] : p.protocol
    baseURL = p.baseUrl
    keyMode = p.auth == "bearer" ? .env : p.auth == "none" ? .none : .key
    keyEnv = p.keyEnv ?? ""
    model = p.model ?? ""
    if case .object(let meta)? = p.provider["model_metadata"] {
      // keep the order the provider lists them in
      models = p.models.compactMap { id in
        if case .object(let m)? = meta[id] { return ModelDraft(id: id, m) }
        return ModelDraft(id: id, [:])
      }
    }
    if case .object(let t)? = p.provider["timeouts"] {
      connect = t["connect_ms"]?.int.map(String.init) ?? ""
      firstResponse = t["first_response_ms"]?.int.map(String.init) ?? ""
      stall = t["stall_ms"]?.int.map(String.init) ?? ""
    }
  }

  var modelIDs: [String] { models.map(\.modelID.trimmed).filter { !$0.isEmpty } }

  /** The provider to save, starting from the saved one so nothing the form doesn't show is lost. */
  func provider() throws -> [String: JSON] {
    var p = original?.provider ?? [:]
    p["display_name"] = displayName.trimmed.isEmpty ? nil : .string(displayName.trimmed)
    p["protocol"] = .string(proto)
    p["base_url"] = .string(baseURL.trimmed)
    switch keyMode {
    case .none:
      p["auth"] = .object(["type": .string("none")])
    case .key:
      if !key.trimmed.isEmpty {
        p["auth"] = .object(["type": .string("key"), "key": .string(key.trimmed)])
      } else if original?.auth == "key" {
        // the bridge keeps the saved key when this one has none
        p["auth"] = .object(["type": .string("key")])
      } else {
        throw LinkError("Enter the API key, or choose No key.")
      }
    case .env:
      guard !keyEnv.trimmed.isEmpty else { throw LinkError("Enter the variable that holds the key.") }
      p["auth"] = .object(["type": .string("bearer"), "env": .string(keyEnv.trimmed)])
    }
    var timeouts: [String: JSON] = [:]
    if case .object(let t)? = p["timeouts"] { timeouts = t }
    for (k, v) in [("connect_ms", connect), ("first_response_ms", firstResponse), ("stall_ms", stall)] {
      timeouts[k] = Int(v.trimmed).map { .number(Double($0)) }
    }
    p["timeouts"] = timeouts.isEmpty ? nil : .object(timeouts)
    var seen = Set<String>()
    var meta: [String: JSON] = [:]
    for m in models where !m.modelID.trimmed.isEmpty {
      guard seen.insert(m.modelID.trimmed).inserted else { throw LinkError("\(m.modelID) is listed twice.") }
      meta[m.modelID.trimmed] = .object(m.metadata())
    }
    guard !meta.isEmpty else { throw LinkError("Add at least one model.") }
    p["model_metadata"] = .object(meta)
    return p
  }
}

extension String {
  var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: Provider form

private struct ProviderForm: View {
  @Environment(Link.self) private var link
  @Environment(\.dismiss) private var dismiss
  @State var draft: ProviderDraft
  let host: String
  /** names already on this host, which a new or renamed provider can't take */
  let taken: Set<String>
  let saved: ([ProviderSummary]) -> Void
  @State private var saving = false
  @State private var problem: String?
  @State private var confirmDelete = false

  private var editing: Bool { draft.original != nil }
  private var cloud: Bool { host == "cloud" }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Display name", text: $draft.displayName, prompt: Text("e.g. OpenCode Go"))
            .accessibilityIdentifier("providerDisplayName")
          LabeledContent("ID") {
            TextField("ID", text: $draft.name, prompt: Text("e.g. oc-go"))
              .multilineTextAlignment(.trailing)
              .font(.geistMono(14))
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .accessibilityIdentifier("providerName")
          }
          Picker("Protocol", selection: $draft.proto) {
            Text("OpenAI Chat Completions").tag(ProviderDraft.protocols[0])
            Text("OpenAI Responses").tag(ProviderDraft.protocols[1])
            Text("Anthropic Messages").tag(ProviderDraft.protocols[2])
          }
          TextField("Base URL", text: $draft.baseURL, prompt: Text("https://api.example.com/v1"))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .accessibilityIdentifier("providerURL")
        } footer: {
          Text("Menus show the display name. The ID is what spark and its settings call the provider.")
        }

        Section {
          Picker("Key", selection: $draft.keyMode) {
            Text("API key").tag(ProviderDraft.KeyMode.key)
            Text("Variable").tag(ProviderDraft.KeyMode.env)
            Text("None").tag(ProviderDraft.KeyMode.none)
          }
          .pickerStyle(.segmented)
          switch draft.keyMode {
          case .key:
            SecureField(keyPrompt, text: $draft.key)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .accessibilityIdentifier("providerKey")
          case .env:
            TextField("Variable", text: $draft.keyEnv, prompt: Text("OPENAI_API_KEY"))
              .font(.geistMono(14))
              .textInputAutocapitalization(.characters)
              .autocorrectionDisabled()
          case .none:
            EmptyView()
          }
        } header: {
          Text("Authentication")
        } footer: {
          switch draft.keyMode {
          case .key: Text(keyNotice(cloud: cloud))
          case .env: Text(cloud ? "The cloud reads the key from this variable in its own environment." : "spark reads the key from this variable in your Mac's shell.")
          case .none: Text("Requests go without an Authorization header.")
          }
        }

        Section {
          ForEach($draft.models) { $m in
            NavigationLink {
              ModelForm(model: $m)
            } label: {
              VStack(alignment: .leading, spacing: 2) {
                HStack {
                  Text(m.modelID.isEmpty ? "New model" : m.title).lineLimit(1)
                  if m.modelID.trimmed == draft.model { Image(systemName: "star.fill").font(.caption2).foregroundStyle(Color.dim) }
                }
                Text(summary(m)).font(.geist(12)).foregroundStyle(Color.faint).lineLimit(1)
              }
            }
            .accessibilityIdentifier("model-\(m.modelID)")
          }
          .onDelete { draft.models.remove(atOffsets: $0) }
          .onMove { draft.models.move(fromOffsets: $0, toOffset: $1) }
          Button("Add model", systemImage: "plus") {
            var m = ModelDraft()
            if let last = draft.models.last {
              // a new model usually shares its neighbour's limits and levels
              m.context = last.context
              m.efforts = last.efforts
              m.savedEfforts = last.savedEfforts
            }
            draft.models.append(m)
          }
          .accessibilityIdentifier("addModel")
          if !draft.modelIDs.isEmpty {
            Picker("Default model", selection: $draft.model) {
              Text("First in the list").tag("")
              ForEach(draft.models.filter { !$0.modelID.trimmed.isEmpty }) { Text($0.title).tag($0.modelID.trimmed) }
            }
          }
        } header: {
          Text("Models")
        } footer: {
          Text("Tap a model to set its name, context window, and reasoning levels. Swipe to delete.")
        }

        Section {
          number("Connect", $draft.connect)
          number("First response", $draft.firstResponse)
          number("Stall", $draft.stall)
        } header: {
          Text("Timeouts")
        } footer: {
          Text("In milliseconds. Empty keeps spark's own limit.")
        }

        if let problem {
          Section { Text(problem).foregroundStyle(Color(red: 1, green: 0.42, blue: 0.4)) }
        }
        if editing {
          Section {
            Button("Delete provider", role: .destructive) { confirmDelete = true }
          }
        }
      }
      .scrollContentBackground(.hidden)
      .page()
      .navigationTitle(editing ? (draft.original?.title ?? draft.name) : "New provider")
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
              .disabled(draft.name.trimmed.isEmpty || draft.baseURL.trimmed.isEmpty)
              .accessibilityIdentifier("saveProvider")
          }
        }
      }
      .confirmationDialog("Delete \(draft.original?.title ?? draft.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
        Button("Delete", role: .destructive) { remove() }
      }
    }
    .presentationBackground(Color.page)
    .interactiveDismissDisabled(saving)
  }

  private func number(_ label: String, _ value: Binding<String>) -> some View {
    LabeledContent(label) {
      TextField("Default", text: value)
        .multilineTextAlignment(.trailing)
        .keyboardType(.numberPad)
    }
  }

  private func summary(_ m: ModelDraft) -> String {
    var parts: [String] = []
    if !m.displayName.isEmpty { parts.append(m.modelID) }
    if let n = ModelDraft.tokens(m.context) { parts.append("\(compact(n)) context") }
    if !m.efforts.isEmpty { parts.append(m.efforts.joined(separator: ", ")) }
    if !m.tools { parts.append("no tools") }
    return parts.isEmpty ? "No limits set" : parts.joined(separator: " · ")
  }

  private var keyPrompt: String {
    if let hint = draft.original?.keyHint { return "Saved key \(hint); empty keeps it" }
    return "API key"
  }

  private func save() {
    let name = draft.name.trimmed
    if name != draft.original?.name, taken.contains(name) {
      problem = "There's already a provider named \(name)."
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
        saved(try await link.putProvider(name, provider, model: draft.model, previous: draft.original?.name, on: host))
        dismiss()
      } catch {
        problem = error.localizedDescription
      }
    }
  }

  private func remove() {
    guard let name = draft.original?.name else { return }
    saving = true
    Task {
      defer { saving = false }
      do {
        saved(try await link.deleteProvider(name, on: host))
        dismiss()
      } catch {
        problem = error.localizedDescription
      }
    }
  }
}

/** 1000000 → "1M", 200000 → "200K" */
private func compact(_ n: Int) -> String {
  if n >= 1_000_000, n % 100_000 == 0 { return n % 1_000_000 == 0 ? "\(n / 1_000_000)M" : String(format: "%.1fM", Double(n) / 1_000_000) }
  if n >= 1000, n % 1000 == 0 { return "\(n / 1000)K" }
  return "\(n)"
}

// MARK: Model form

private struct ModelForm: View {
  @Binding var model: ModelDraft
  @State private var custom = ""

  private static let contexts = [32_000, 128_000, 200_000, 256_000, 400_000, 1_000_000, 2_000_000]

  var body: some View {
    Form {
      Section {
        LabeledContent("ID") {
          TextField("ID", text: $model.modelID, prompt: Text("e.g. glm-5.3"))
            .multilineTextAlignment(.trailing)
            .font(.geistMono(14))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier("modelID")
        }
        TextField("Display name", text: $model.displayName, prompt: Text("e.g. GLM 5.3"))
          .accessibilityIdentifier("modelDisplayName")
      } footer: {
        Text("The ID is the name the server expects.")
      }

      Section {
        LabeledContent("Context window") {
          HStack(spacing: 6) {
            TextField("Unknown", text: $model.context)
              .multilineTextAlignment(.trailing)
              .keyboardType(.asciiCapable)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .accessibilityIdentifier("modelContext")
            Menu {
              ForEach(Self.contexts, id: \.self) { n in
                Button(compact(n)) { model.context = String(n) }
              }
            } label: {
              Image(systemName: "chevron.up.chevron.down").font(.caption)
            }
          }
        }
        LabeledContent("Max output") {
          TextField("Unknown", text: $model.maxOutput)
            .multilineTextAlignment(.trailing)
            .keyboardType(.asciiCapable)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
      } header: {
        Text("Limits")
      } footer: {
        Text("In tokens. 200k and 1m work too.")
      }

      Section {
        Toggle("Tool use", isOn: $model.tools).tint(.green)
        Toggle("Images", isOn: $model.vision).tint(.green)
      } header: {
        Text("Supports")
      }

      Section {
        ForEach(levels, id: \.self) { level in
          Button {
            toggle(level)
          } label: {
            HStack {
              Text(level).foregroundStyle(.white)
              Spacer()
              if model.efforts.contains(level) { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
          }
          .accessibilityIdentifier("effort-\(level)")
        }
        HStack {
          TextField("Other level", text: $custom)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onSubmit(addCustom)
          Button("Add", action: addCustom).disabled(custom.trimmed.isEmpty)
        }
      } header: {
        Text("Reasoning levels")
      } footer: {
        Text("The levels spark offers for this model. None checked: the model has no reasoning levels. A new level sends reasoning_effort with its name.")
      }
    }
    .scrollContentBackground(.hidden)
    .page()
    .navigationTitle(model.modelID.isEmpty ? "New model" : model.title)
    .navigationBarTitleDisplayMode(.inline)
  }

  /** the common levels, then any others this model has */
  private var levels: [String] {
    ModelDraft.commonEfforts + model.efforts.filter { !ModelDraft.commonEfforts.contains($0) }
  }

  private func toggle(_ level: String) {
    if let i = model.efforts.firstIndex(of: level) {
      model.efforts.remove(at: i)
    } else {
      model.efforts.append(level)
      model.efforts.sort { ModelDraft.rank($0) < ModelDraft.rank($1) }
    }
  }

  private func addCustom() {
    let level = custom.trimmed
    guard !level.isEmpty, !model.efforts.contains(level) else { return }
    model.efforts.append(level)
    custom = ""
  }
}

// MARK: Prompts

/** The shared prompts: each one a whole system prompt a new chat can start with instead of spark's own. */
struct PromptsView: View {
  @Environment(Link.self) private var link
  @State private var loaded = false
  @State private var problem: String?
  @State private var editing: PromptDraft?
  @State private var renaming: PromptSummary?
  @State private var newName = ""
  @State private var deleting: PromptSummary?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        if loaded {
          if link.prompts.isEmpty {
            Text("There are no prompts yet. A prompt replaces spark's own system prompt for the chats that pick it.")
              .font(.geist(15))
              .foregroundStyle(Color.dim)
              .padding(.horizontal, 6)
          } else {
            VStack(spacing: 0) {
              ForEach(link.prompts) { p in
                Button { editing = PromptDraft(p) } label: { row(p) }
                  .buttonStyle(.plain)
                  .contextMenu {
                    Button("Rename", systemImage: "pencil") {
                      newName = p.name
                      renaming = p
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) { deleting = p }
                  }
                  .accessibilityIdentifier("prompt-\(p.name)")
                if p.id != link.prompts.last?.id { Divider().overlay(Color.hairline).padding(.leading, 58) }
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
        Button { editing = PromptDraft() } label: {
          HStack(spacing: 12) {
            Image(systemName: "plus")
              .font(.system(size: 14, weight: .semibold))
              .frame(width: 34, height: 34)
              .background(Color.white.opacity(0.07), in: .rect(cornerRadius: 10, style: .continuous))
            Text("New prompt").font(.geist(16))
            Spacer(minLength: 0)
          }
          .foregroundStyle(.white)
          .padding(.horizontal, 12)
          .padding(.vertical, 10)
          .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(Color.white.opacity(0.05), in: .rect(cornerRadius: 22, style: .continuous))
        .accessibilityIdentifier("addPrompt")
        Text("Pick a prompt in the composer of a new chat. On a Mac, spark lists these with your own prompts under /prompt. Chats already open keep the prompt they started with.")
          .font(.geist(13))
          .foregroundStyle(Color.faint)
          .padding(.horizontal, 6)
      }
      .padding(.horizontal, 16)
      .padding(.top, 8)
      .padding(.bottom, 32)
    }
    .page()
    .navigationTitle("Prompts")
    .navigationBarTitleDisplayMode(.inline)
    .refreshable { await load() }
    .task { await load() }
    .animation(.ease, value: link.prompts)
    .sheet(item: $editing) { draft in PromptEditor(draft: draft) }
    .alert("Rename prompt", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
      TextField("Name", text: $newName)
      Button("Cancel", role: .cancel) {}
      Button("Rename") {
        guard let p = renaming else { return }
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != p.name else { return }
        Task { await run { try await link.putPrompt(name, text: p.text, previous: p.name) } }
      }
    }
    .confirmationDialog("Delete \(deleting?.name ?? "this prompt")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
      Button("Delete", role: .destructive) {
        if let p = deleting { Task { await run { try await link.deletePrompt(p.name) } } }
        deleting = nil
      }
    } message: {
      Text("Chats that use it keep running with spark's own prompt.")
    }
  }

  private func row(_ p: PromptSummary) -> some View {
    HStack(spacing: 12) {
      Image(systemName: "text.quote")
        .font(.system(size: 14, weight: .medium))
        .frame(width: 34, height: 34)
        .background(Color.white.opacity(0.07), in: .rect(cornerRadius: 10, style: .continuous))
      VStack(alignment: .leading, spacing: 2) {
        Text(p.name).font(.geist(16)).lineLimit(1)
        Text(preview(p.text)).font(.geist(13)).foregroundStyle(Color.dim).lineLimit(1)
      }
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

  private func preview(_ text: String) -> String {
    let line = text.split(whereSeparator: \.isNewline).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    return line.map { String($0).trimmingCharacters(in: .whitespaces) } ?? "Empty"
  }

  private func load() async {
    await run { try await link.loadPrompts() }
    loaded = true
  }

  private func run(_ f: () async throws -> some Any) async {
    do {
      _ = try await f()
      problem = nil
    } catch {
      problem = error.localizedDescription
    }
  }
}

struct PromptDraft: Identifiable {
  let id = UUID()
  /** the saved name, for a prompt that exists */
  var original: String?
  var name = ""
  var text = ""

  init() {}
  init(_ p: PromptSummary) {
    original = p.name
    name = p.name
    text = p.text
  }
}

/** A prompt's name and its whole text, edited like a note. */
private struct PromptEditor: View {
  @Environment(Link.self) private var link
  @Environment(\.dismiss) private var dismiss
  @State var draft: PromptDraft
  @State private var saving = false
  @State private var problem: String?
  @FocusState private var focus: Field?

  private enum Field { case name, text }

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 0) {
        TextField("Name", text: $draft.name)
          .font(.geist(22, .semibold))
          .focused($focus, equals: .name)
          .submitLabel(.next)
          .onSubmit { focus = .text }
          .padding(.horizontal, 20)
          .padding(.top, 12)
          .padding(.bottom, 8)
          .accessibilityIdentifier("promptName")
        if let problem {
          Text(problem).font(.geist(13)).foregroundStyle(Color(red: 1, green: 0.42, blue: 0.4)).padding(.horizontal, 20).padding(.bottom, 6)
        }
        Divider().overlay(Color.hairline)
        TextEditor(text: $draft.text)
          .font(.geistMono(14))
          .scrollContentBackground(.hidden)
          .focused($focus, equals: .text)
          .padding(.horizontal, 15)
          .overlay(alignment: .topLeading) {
            if draft.text.isEmpty {
              Text("You are a careful reviewer…")
                .font(.geistMono(14))
                .foregroundStyle(Color.faint)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .allowsHitTesting(false)
            }
          }
          .accessibilityIdentifier("promptText")
      }
      .page()
      .navigationTitle(draft.original == nil ? "New prompt" : "Edit prompt")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Cancel", systemImage: "xmark") { dismiss() }
        }
        ToolbarItem(placement: .topBarTrailing) {
          if saving {
            ProgressView()
          } else {
            Button("Save", systemImage: "checkmark") { Task { await save() } }
              .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
              .accessibilityIdentifier("savePrompt")
          }
        }
      }
      .onAppear { focus = draft.original == nil ? .name : .text }
    }
    .presentationBackground(Color.page)
  }

  private func save() async {
    saving = true
    defer { saving = false }
    do {
      try await link.putPrompt(draft.name.trimmingCharacters(in: .whitespacesAndNewlines), text: draft.text, previous: draft.original)
      dismiss()
    } catch {
      problem = error.localizedDescription
    }
  }
}
