import SwiftUI
import UIKit

/** The chat's folder on its host: walk into folders, open files, and change them. */
struct FilesView: View {
  let host: String
  let root: String

  var body: some View {
    NavigationStack {
      FolderScreen(host: host, path: root, title: Self.name(root), root: true)
        .navigationDestination(for: FileEntry.self) { e in
          if e.dir {
            FolderScreen(host: host, path: e.path, title: e.name, root: false)
          } else {
            FileScreen(host: host, entry: e)
          }
        }
    }
    .tint(.white)
    .presentationDetents([.large])
    .presentationBackground(Color.page)
  }

  static func name(_ path: String) -> String {
    path.split(separator: "/").last.map(String.init) ?? path
  }
}

/** What the browser is asking a name for. */
private enum Naming: Identifiable {
  case file, folder
  case rename(FileEntry)

  var id: String {
    switch self {
    case .file: "file"
    case .folder: "folder"
    case .rename(let e): "rename:\(e.path)"
    }
  }
}

private struct FolderScreen: View {
  @Environment(Link.self) private var link
  @Environment(\.dismiss) private var dismiss
  let host: String
  let path: String
  let title: String
  let root: Bool

  @State private var listing: FileListing?
  @State private var problem: String?
  @State private var query = ""
  @State private var naming: Naming?
  @State private var name = ""
  @State private var deleting: FileEntry?
  /** a file just made opens in the editor */
  @State private var opened: FileEntry?
  @State private var delivery: Delivery?

  var body: some View {
    content
      .page()
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        if root {
          ToolbarItem(placement: .topBarLeading) {
            Button("Close", systemImage: "xmark") { dismiss() }
          }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Menu("New", systemImage: "plus") {
            Button("New File", systemImage: "doc.badge.plus") { ask(.file) }
            Button("New Folder", systemImage: "folder.badge.plus") { ask(.folder) }
          }
        }
      }
      .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Filter")
      .navigationDestination(item: $opened) { FileScreen(host: host, entry: $0, editing: true) }
      .onAppear { Task { await load() } }
      .refreshable { await load() }
      .delivers(from: host, $delivery)
      .alert(namingTitle, isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
        TextField("Name", text: $name)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        Button(namingAction) { commit() }
        Button("Cancel", role: .cancel) {}
      }
      .alert(
        "Delete \(deleting?.name ?? "")?",
        isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
      ) {
        Button("Delete", role: .destructive) { remove() }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(deleting?.dir == true ? "The folder and everything in it are deleted for good." : "The file is deleted for good.")
      }
      .alert("Couldn't do that", isPresented: Binding(get: { problem != nil && listing != nil }, set: { if !$0 { problem = nil } })) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(problem ?? "")
      }
  }

  @ViewBuilder private var content: some View {
    if let listing {
      let shown = filtered(listing.entries)
      List {
        ForEach(shown) { e in
          NavigationLink(value: e) { EntryRow(entry: e) }
            .swipeActions(edge: .trailing) {
              Button("Delete", systemImage: "trash", role: .destructive) { deleting = e }
              Button("Rename", systemImage: "pencil") { ask(.rename(e)) }
                .tint(Color(white: 0.3))
            }
            .swipeActions(edge: .leading) {
              if !e.dir {
                Button("Share", systemImage: "square.and.arrow.up") { delivery = Delivery(path: e.path, kind: .share) }
                  .tint(Color(white: 0.3))
              }
            }
            .contextMenu {
              if !e.dir {
                Button("Share\u{2026}", systemImage: "square.and.arrow.up") { delivery = Delivery(path: e.path, kind: .share) }
                Button("Save to Files", systemImage: "arrow.down.doc") { delivery = Delivery(path: e.path, kind: .save) }
                Divider()
              }
              Button("Rename", systemImage: "pencil") { ask(.rename(e)) }
              Button("Copy Path", systemImage: "doc.on.doc") { UIPasteboard.general.string = e.path }
              Divider()
              Button("Delete", systemImage: "trash", role: .destructive) { deleting = e }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            .listRowSeparatorTint(Color.hairline)
        }
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .animation(.smooth(duration: 0.28), value: shown.map(\.id))
      .overlay {
        if shown.isEmpty {
          Text(query.isEmpty ? "Empty folder" : "Nothing matches").font(.geist(15)).foregroundStyle(Color.faint)
        }
      }
    } else if let problem {
      VStack(spacing: 14) {
        Text(problem).font(.geist(15)).foregroundStyle(Color.dim).multilineTextAlignment(.center)
        Button("Try again") { Task { await load() } }
          .font(.geist(15, .medium))
      }
      .padding(32)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ProgressView().tint(Color.dim).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func filtered(_ entries: [FileEntry]) -> [FileEntry] {
    let q = query.trimmingCharacters(in: .whitespaces)
    return q.isEmpty ? entries : entries.filter { $0.name.localizedCaseInsensitiveContains(q) }
  }

  private var namingTitle: String {
    switch naming {
    case .file: "New file"
    case .folder: "New folder"
    case .rename(let e): e.dir ? "Rename folder" : "Rename file"
    case nil: ""
    }
  }

  private var namingAction: String {
    if case .rename = naming { return "Rename" }
    return "Create"
  }

  private func ask(_ n: Naming) {
    if case .rename(let e) = n { name = e.name } else { name = "" }
    naming = n
  }

  private func load() async {
    do {
      let l = try await link.files(host, path)
      problem = nil
      listing = l
    } catch {
      problem = error.localizedDescription
    }
  }

  private func commit() {
    let n = name.trimmingCharacters(in: .whitespaces)
    guard let what = naming, !n.isEmpty else { return }
    Task {
      do {
        switch what {
        case .file:
          let made = try await link.createEntry(host, in: path, name: n, dir: false)
          await load()
          opened = FileEntry(name: n, path: made, dir: false, size: 0)
        case .folder:
          _ = try await link.createEntry(host, in: path, name: n, dir: true)
          await load()
        case .rename(let e):
          guard n != e.name else { return }
          _ = try await link.renameEntry(host, e.path, to: n)
          await load()
        }
      } catch {
        problem = error.localizedDescription
      }
    }
  }

  private func remove() {
    guard let e = deleting else { return }
    // gone from the list at once; back if the host refuses
    let before = listing
    listing?.entries.removeAll { $0.id == e.id }
    Task {
      do {
        try await link.deleteEntry(host, e.path)
      } catch {
        listing = before
        problem = error.localizedDescription
      }
    }
  }
}

private struct EntryRow: View {
  let entry: FileEntry

  var body: some View {
    HStack(spacing: 14) {
      FileIcon(name: entry.name, dir: entry.dir)
        .opacity(entry.hidden ? 0.6 : 1)
      Text(entry.name)
        .font(.geist(16))
        .foregroundStyle(entry.hidden ? Color.dim : .white)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 8)
      if let size = entry.size {
        Text(Int64(size).formatted(.byteCount(style: .file)))
          .font(.geistMono(11))
          .foregroundStyle(Color.faint)
      }
    }
    .padding(.vertical, 11)
    .contentShape(.rect)
  }
}

/** One file: read it, edit it if it's text, rename or delete it. */
private struct FileScreen: View {
  @Environment(Link.self) private var link
  @Environment(\.dismiss) private var dismiss
  let host: String
  @State private var entry: FileEntry
  @State private var content: FileContent?
  @State private var lines: [String] = []
  @State private var problem: String?
  @State private var editing: Bool
  @State private var draft = ""
  @State private var saving = false
  @State private var source = false
  @State private var renaming = false
  @State private var deleting = false
  @State private var name = ""
  @State private var delivery: Delivery?
  @FocusState private var focused: Bool

  init(host: String, entry: FileEntry, editing: Bool = false) {
    self.host = host
    _entry = State(initialValue: entry)
    _editing = State(initialValue: editing)
  }

  private var markdown: Bool {
    ["md", "mdx", "markdown"].contains((entry.name as NSString).pathExtension.lowercased())
  }

  private var editable: Bool { content?.kind == .text && content?.truncated != true }
  private var changed: Bool { editing && draft != (content?.text ?? "") }

  var body: some View {
    body(for: content)
      .page()
      .navigationTitle(entry.name)
      .navigationBarTitleDisplayMode(.inline)
      .navigationBarBackButtonHidden(editing)
      .interactiveDismissDisabled(changed)
      .toolbar { toolbar }
      .task { await load() }
      .delivers(from: host, $delivery)
      .alert("Rename file", isPresented: $renaming) {
        TextField("Name", text: $name)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        Button("Rename") { rename() }
        Button("Cancel", role: .cancel) {}
      }
      .alert("Delete \(entry.name)?", isPresented: $deleting) {
        Button("Delete", role: .destructive) { remove() }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("The file is deleted for good.")
      }
      .alert("Couldn't do that", isPresented: Binding(get: { problem != nil && content != nil }, set: { if !$0 { problem = nil } })) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(problem ?? "")
      }
      .sensoryFeedback(.success, trigger: saving) { was, now in was && !now && problem == nil }
  }

  @ToolbarContentBuilder private var toolbar: some ToolbarContent {
    if editing {
      ToolbarItem(placement: .topBarLeading) {
        Button("Cancel") {
          focused = false
          editing = false
        }
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button("Save") { save() }
          .fontWeight(.semibold)
          .disabled(!changed || saving)
      }
    } else if content != nil {
      ToolbarItemGroup(placement: .topBarTrailing) {
        if editable {
          Button("Edit", systemImage: "pencil") { edit() }
        }
        Button("Share", systemImage: "square.and.arrow.up") { delivery = Delivery(path: entry.path, kind: .share) }
        Menu("More", systemImage: "ellipsis") {
          Button("Save to Files", systemImage: "arrow.down.doc") { delivery = Delivery(path: entry.path, kind: .save) }
          if markdown, content?.kind == .text {
            Button(source ? "Show Preview" : "Show Source", systemImage: source ? "eye" : "chevron.left.forwardslash.chevron.right") { source.toggle() }
          }
          Button("Copy Path", systemImage: "doc.on.doc") { UIPasteboard.general.string = entry.path }
          if let text = content?.text {
            Button("Copy Contents", systemImage: "doc.on.clipboard") { UIPasteboard.general.string = text }
          }
          Button("Rename", systemImage: "pencil") {
            name = entry.name
            renaming = true
          }
          Divider()
          Button("Delete", systemImage: "trash", role: .destructive) { deleting = true }
        }
      }
    }
  }

  @ViewBuilder private func body(for content: FileContent?) -> some View {
    if let content {
      switch content.kind {
      case .text where editing:
        TextEditor(text: $draft)
          .font(.geistMono(13))
          .focused($focused)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .scrollContentBackground(.hidden)
          .padding(.horizontal, 12)
          .onAppear { focused = true }
      case .text where markdown && !source:
        ScrollView {
          MarkdownView(text: content.text ?? "", ink: nil)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      case .text:
        CodeLines(lines: lines, truncated: content.truncated == true)
      case .image:
        if let data = content.data.flatMap({ Data(base64Encoded: $0) }), let image = UIImage(data: data) {
          ZoomableImage(image: image)
        } else {
          Unviewable(content: content, why: "spark couldn't draw this image.")
        }
      case .binary:
        Unviewable(content: content, why: content.size > 4 << 20 && FileStyle.isImage(content.name) ? "This image is too big to send to the phone." : "spark can't show this kind of file.")
      }
    } else if let problem {
      Text(problem).font(.geist(15)).foregroundStyle(Color.dim).multilineTextAlignment(.center).padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ProgressView().tint(Color.dim).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func load() async {
    do {
      let c = try await link.file(host, entry.path)
      lines = (c.text ?? "").components(separatedBy: "\n")
      if lines.count > 1, lines.last == "" { lines.removeLast() }
      content = c
      if editing {
        if c.kind == .text, c.truncated != true { draft = c.text ?? "" } else { editing = false }
      }
    } catch {
      problem = error.localizedDescription
    }
  }

  private func edit() {
    draft = content?.text ?? ""
    editing = true
  }

  private func save() {
    guard let content, !saving else { return }
    saving = true
    let text = draft
    Task {
      defer { saving = false }
      do {
        let saved = try await link.saveFile(host, entry.path, text: text, modified: content.modified)
        problem = nil
        self.content?.text = text
        self.content?.modified = saved.modified
        self.content?.size = saved.size
        lines = text.components(separatedBy: "\n")
        if lines.count > 1, lines.last == "" { lines.removeLast() }
        focused = false
        editing = false
      } catch {
        problem = error.localizedDescription
      }
    }
  }

  private func rename() {
    let n = name.trimmingCharacters(in: .whitespaces)
    guard !n.isEmpty, n != entry.name else { return }
    Task {
      do {
        let path = try await link.renameEntry(host, entry.path, to: n)
        entry = FileEntry(name: n, path: path, dir: false, size: entry.size)
        content?.path = path
        content?.name = n
      } catch {
        problem = error.localizedDescription
      }
    }
  }

  private func remove() {
    Task {
      do {
        try await link.deleteEntry(host, entry.path)
        dismiss()
      } catch {
        problem = error.localizedDescription
      }
    }
  }
}

extension FileStyle {
  static func isImage(_ name: String) -> Bool {
    ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff", "ico"].contains((name as NSString).pathExtension.lowercased())
  }
}

/** A text file, numbered, one row per line so a long file only lays out what's on screen. */
private struct CodeLines: View {
  let lines: [String]
  let truncated: Bool

  var body: some View {
    let gutter = CGFloat(String(lines.count).count) * 8 + 4
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(lines.indices, id: \.self) { i in
          HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(i + 1)")
              .font(.geistMono(11))
              .foregroundStyle(Color.faint)
              .frame(width: gutter, alignment: .trailing)
            Text(lines[i].isEmpty ? " " : lines[i])
              .font(.geistMono(12.5))
              .foregroundStyle(Color(white: 0.86))
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .padding(.vertical, 1.5)
        }
        if truncated {
          Text("The file goes on. The phone shows the first 512 KB.")
            .font(.geist(13))
            .foregroundStyle(Color.faint)
            .padding(.top, 16)
        }
      }
      .textSelection(.enabled)
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
    }
  }
}

/** An image that fits the screen and zooms with a pinch or a double tap. */
private struct ZoomableImage: View {
  let image: UIImage
  @State private var scale: CGFloat = 1
  @State private var settled: CGFloat = 1

  var body: some View {
    Image(uiImage: image)
      .resizable()
      .interpolation(image.size.width < 128 ? .none : .high)
      .scaledToFit()
      .scaleEffect(scale)
      .padding(20)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .contentShape(.rect)
      .gesture(
        MagnifyGesture()
          .onChanged { scale = max(1, settled * $0.magnification) }
          .onEnded { _ in settled = scale }
      )
      .onTapGesture(count: 2) {
        withAnimation(.smooth(duration: 0.3)) { scale = scale > 1 ? 1 : 2.5 }
        settled = scale
      }
  }
}

private struct Unviewable: View {
  let content: FileContent
  let why: String

  var body: some View {
    VStack(spacing: 12) {
      FileIcon(name: content.name, dir: false, size: 52)
      Text(content.name).font(.geist(17, .medium)).foregroundStyle(.white)
      Text(Int64(content.size).formatted(.byteCount(style: .file))).font(.geistMono(12)).foregroundStyle(Color.faint)
      Text(why).font(.geist(14)).foregroundStyle(Color.dim).padding(.top, 4)
    }
    .multilineTextAlignment(.center)
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
