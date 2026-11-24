import SwiftUI

/** The shared MCP servers: the cloud runs them, and every paired Mac gets a copy in its mcp.json. */
struct McpServersView: View {
  @Environment(Link.self) private var link
  @State private var loaded = false
  @State private var problem: String?
  @State private var editing: McpDraft?
  @State private var deleting: McpSummary?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        if loaded {
          if link.mcpLibrary.isEmpty {
            Text("There are no MCP servers yet. A server gives spark more tools, in the cloud and on every paired Mac.")
              .font(.geist(15))
              .foregroundStyle(Color.dim)
              .padding(.horizontal, 6)
          } else {
            VStack(spacing: 0) {
              ForEach(link.mcpLibrary) { m in
                row(m)
                  .contextMenu {
                    Button("Edit", systemImage: "pencil") { editing = McpDraft(m) }
                    Button("Delete", systemImage: "trash", role: .destructive) { deleting = m }
                  }
                if m.id != link.mcpLibrary.last?.id { Divider().overlay(Color.hairline).padding(.leading, 58) }
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
        Button { editing = McpDraft() } label: {
          HStack(spacing: 12) {
            Image(systemName: "plus")
              .font(.system(size: 14, weight: .semibold))
              .frame(width: 34, height: 34)
              .background(Color.white.opacity(0.07), in: .rect(cornerRadius: 10, style: .continuous))
            Text("New MCP server").font(.geist(16))
            Spacer(minLength: 0)
          }
          .foregroundStyle(.white)
          .padding(.horizontal, 12)
          .padding(.vertical, 10)
          .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(Color.white.opacity(0.05), in: .rect(cornerRadius: 22, style: .continuous))
        .accessibilityIdentifier("addMcp")
        Text("A server that runs a command starts wherever the chat runs, so the command has to be there too. Chats pick up changes at their next message, and a chat can turn any server off from its model picker. On a Mac, spark mcp edits these too.")
          .font(.geist(13))
          .foregroundStyle(Color.faint)
          .padding(.horizontal, 6)
      }
      .padding(.horizontal, 16)
      .padding(.top, 8)
      .padding(.bottom, 32)
      .readable(640)
    }
    .page()
    .navigationTitle("MCP Servers")
    .navigationBarTitleDisplayMode(.inline)
    .refreshable { await load() }
    .task { await load() }
    .animation(.ease, value: link.mcpLibrary)
    .sheet(item: $editing) { draft in McpForm(draft: draft, taken: Set(link.mcpLibrary.map(\.name))) }
    .confirmationDialog("Delete \(deleting?.name ?? "this server")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
      Button("Delete", role: .destructive) {
        if let m = deleting { Task { await run { try await link.deleteMcp(m.name) } } }
        deleting = nil
      }
    } message: {
      Text("It leaves the cloud and every paired Mac.")
    }
  }

  private func row(_ m: McpSummary) -> some View {
    HStack(spacing: 12) {
      Button { editing = McpDraft(m) } label: {
        HStack(spacing: 12) {
          Image(systemName: m.url == nil ? "terminal" : "globe")
            .font(.system(size: 14, weight: .medium))
            .frame(width: 34, height: 34)
            .background(Color.white.opacity(0.07), in: .rect(cornerRadius: 10, style: .continuous))
          VStack(alignment: .leading, spacing: 2) {
            Text(m.name).font(.geist(16)).lineLimit(1)
            Text(m.detail).font(.geistMono(12)).foregroundStyle(Color.dim).lineLimit(1).truncationMode(.middle)
          }
          Spacer(minLength: 0)
        }
        .opacity(m.enabled ? 1 : 0.5)
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("mcp-\(m.name)")
      Toggle(m.name, isOn: Binding(get: { m.enabled }, set: { on in Task { await run { try await link.setMcpEnabled(m.name, on) } } }))
        .labelsHidden()
        .tint(.green)
        .accessibilityIdentifier("mcpEnabled-\(m.name)")
    }
    .foregroundStyle(.white)
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
  }

  private func load() async {
    await run { try await link.loadMcpLibrary() }
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

/** A server being written: a command with its arguments and variables, or a URL with its headers. */
struct McpDraft: Identifiable {
  struct Pair: Identifiable {
    let id = UUID()
    var key = ""
    var value = ""
    /** the name it was saved under, while its value stays on the server */
    var saved: String?
    var hint: String?
  }
  struct Arg: Identifiable {
    let id = UUID()
    var text = ""
  }

  let id = UUID()
  var original: McpSummary?
  var name = ""
  var http = false
  var command = ""
  var args: [Arg] = []
  var url = ""
  /** env for a command, headers for a URL */
  var pairs: [Pair] = []
  var enabled = true

  init() {}

  init(_ m: McpSummary) {
    original = m
    name = m.name
    http = m.url != nil
    command = m.command ?? ""
    args = m.args.map { Arg(text: $0) }
    url = m.url ?? ""
    enabled = m.enabled
    let field = http ? "headers" : "env"
    if case .object(let values) = m.server[field] {
      pairs = values.keys.sorted().map { key in
        if case .string(let v) = values[key] { return Pair(key: key, value: v) }
        return Pair(key: key, saved: key, hint: m.hints["\(field).\(key)"])
      }
    }
  }

  /** the entry for mcp.json; fields spark reads that the form doesn't show are kept */
  func server() throws -> [String: JSON] {
    var out = original?.server ?? [:]
    for key in ["type", "url", "headers", "command", "args", "env", "enabled"] { out[key] = nil }
    var values: [String: JSON] = [:]
    for p in pairs {
      let key = p.key.trimmed
      if key.isEmpty, p.value.isEmpty { continue }
      if key.isEmpty { throw McpDraftError("Give every \(http ? "header" : "variable") a name.") }
      if values[key] != nil { throw McpDraftError("\(key) is there twice.") }
      if p.value.isEmpty {
        guard p.saved == key else { throw McpDraftError("Enter a value for \(key).") }
        values[key] = .null
      } else {
        values[key] = .string(p.value)
      }
    }
    if http {
      out["type"] = .string("http")
      out["url"] = .string(url.trimmed)
      if !values.isEmpty { out["headers"] = .object(values) }
    } else {
      out["command"] = .string(command.trimmed)
      let list = args.map(\.text).filter { !$0.isEmpty }
      if !list.isEmpty { out["args"] = .array(list.map(JSON.string)) }
      if !values.isEmpty { out["env"] = .object(values) }
    }
    if !enabled { out["enabled"] = .bool(false) }
    return out
  }
}

struct McpDraftError: LocalizedError {
  let errorDescription: String?
  init(_ text: String) { errorDescription = text }
}

private struct McpForm: View {
  @Environment(Link.self) private var link
  @Environment(\.dismiss) private var dismiss
  @State var draft: McpDraft
  /** names already in the library, which a new or renamed server can't take */
  let taken: Set<String>
  @State private var saving = false
  @State private var problem: String?
  @State private var confirmDelete = false

  private var editing: Bool { draft.original != nil }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          LabeledContent("Name") {
            TextField("Name", text: $draft.name, prompt: Text("e.g. github"))
              .multilineTextAlignment(.trailing)
              .font(.geistMono(14))
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .accessibilityIdentifier("mcpName")
          }
          Picker("Connects by", selection: $draft.http) {
            Text("Command").tag(false)
            Text("URL").tag(true)
          }
          .pickerStyle(.segmented)
          .accessibilityIdentifier("mcpTransport")
          Toggle("On", isOn: $draft.enabled).tint(.green)
        } footer: {
          Text(draft.http ? "spark connects to the server over HTTP." : "spark starts the command and talks to it over its input and output.")
        }

        if draft.http {
          Section("URL") {
            TextField("URL", text: $draft.url, prompt: Text("https://example.com/mcp"))
              .font(.geistMono(14))
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .keyboardType(.URL)
              .accessibilityIdentifier("mcpURL")
          }
        } else {
          Section {
            TextField("Command", text: $draft.command, prompt: Text("npx"))
              .font(.geistMono(14))
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .accessibilityIdentifier("mcpCommand")
            ForEach($draft.args) { $arg in
              TextField("Argument", text: $arg.text, prompt: Text("Argument"))
                .font(.geistMono(14))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }
            .onDelete { draft.args.remove(atOffsets: $0) }
            .onMove { draft.args.move(fromOffsets: $0, toOffset: $1) }
            Button("Add argument", systemImage: "plus") { draft.args.append(.init()) }
              .accessibilityIdentifier("mcpAddArg")
          } header: {
            Text("Command")
          } footer: {
            Text("One argument per line, as the command gets them. Swipe to delete.")
          }
        }

        Section {
          ForEach($draft.pairs) { $pair in
            VStack(alignment: .leading, spacing: 6) {
              TextField("Name", text: $pair.key, prompt: Text(draft.http ? "Authorization" : "API_KEY"))
                .font(.geistMono(14))
                .textInputAutocapitalization(draft.http ? .never : .characters)
                .autocorrectionDisabled()
              SecureField("Value", text: $pair.value, prompt: Text(valuePrompt(pair)))
                .font(.geistMono(14))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }
            .padding(.vertical, 2)
          }
          .onDelete { draft.pairs.remove(atOffsets: $0) }
          Button(draft.http ? "Add header" : "Add variable", systemImage: "plus") { draft.pairs.append(.init()) }
            .accessibilityIdentifier("mcpAddPair")
        } header: {
          Text(draft.http ? "Headers" : "Environment")
        } footer: {
          Text("Values stay on the server; a saved one shows only its last characters. ${NAME} reads a variable where the server runs.")
        }

        if let problem {
          Section { Text(problem).foregroundStyle(Color(red: 1, green: 0.42, blue: 0.4)) }
        }
        if editing {
          Section {
            Button("Delete server", role: .destructive) { confirmDelete = true }
          }
        }
      }
      .scrollContentBackground(.hidden)
      .page()
      .navigationTitle(editing ? (draft.original?.name ?? draft.name) : "New MCP server")
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
              .disabled(draft.name.trimmed.isEmpty || (draft.http ? draft.url.trimmed.isEmpty : draft.command.trimmed.isEmpty))
              .accessibilityIdentifier("saveMcp")
          }
        }
      }
      .confirmationDialog("Delete \(draft.original?.name ?? draft.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
        Button("Delete", role: .destructive) { remove() }
      } message: {
        Text("It leaves the cloud and every paired Mac.")
      }
    }
    .presentationBackground(Color.page)
    .interactiveDismissDisabled(saving)
  }

  private func valuePrompt(_ pair: McpDraft.Pair) -> String {
    guard pair.saved != nil, pair.key.trimmed == pair.saved else { return "Value" }
    if let hint = pair.hint, !hint.isEmpty { return "Saved …\(hint); empty keeps it" }
    return "Saved; empty keeps it"
  }

  private func save() {
    let name = draft.name.trimmed
    if name != draft.original?.name, taken.contains(name) {
      problem = "There's already an MCP server named \(name)."
      return
    }
    let server: [String: JSON]
    do {
      server = try draft.server()
    } catch {
      problem = error.localizedDescription
      return
    }
    saving = true
    Task {
      defer { saving = false }
      do {
        try await link.putMcp(name, server, previous: draft.original?.name)
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
        try await link.deleteMcp(name)
        dismiss()
      } catch {
        problem = error.localizedDescription
      }
    }
  }
}
