import SwiftUI

/**
 * Choosing where a chat runs: starts at the host's home every time, walks down a folder at a tap,
 * goes up a level from the row at the top or any part of the path, and searches everything below
 * where you are. Folders already seen open at once while the host is asked again.
 */
struct FolderPicker: View {
  @Environment(Link.self) private var link
  @Environment(\.dismiss) private var dismiss
  /** the chosen folder, and how it reads relative to home */
  let chosen: (String, String) -> Void

  @State private var root: String?
  @State private var listing: Listing?
  @State private var query = ""
  @State private var results: [Folder]?
  @State private var searching = false
  @State private var problem: String?
  @State private var naming = false
  @State private var newName = ""
  @State private var moved = 0
  /** every listing seen in this sheet, by path */
  @State private var cache: [String: Listing] = [:]
  @State private var loading: String?
  @State private var target: UUID?
  @State private var renaming: Folder?
  @State private var deleting: Folder?
  @FocusState private var searchFocused: Bool

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        VStack(spacing: 12) {
          HostSwitch()
          searchField
          if query.isEmpty, let listing, listing.path != root { crumbs(listing).transition(.opacity) }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)

        ZStack {
          if !query.isEmpty {
            searchList.transition(.opacity)
          } else if let listing {
            // one list for every folder: moving swaps its rows instead of building a new list
            folderList(listing)
          } else if let problem {
            Text(problem).font(.geist(15)).foregroundStyle(Color.dim).multilineTextAlignment(.center).padding(32)
              .frame(maxHeight: .infinity)
          } else {
            ProgressView().tint(Color.dim).frame(maxHeight: .infinity)
          }
        }
        .frame(maxHeight: .infinity)
        .clipped()
      }
      .page()
      .navigationTitle("Choose a folder")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Close", systemImage: "xmark") { dismiss() }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("New folder", systemImage: "folder.badge.plus") { naming = true }
            .disabled(listing == nil)
        }
      }
      .safeAreaBar(edge: .bottom) {
        if let listing, query.isEmpty {
          Button {
            chosen(listing.path, display(listing.path))
          } label: {
            HStack(spacing: 7) {
              Image(systemName: "checkmark").font(.system(size: 13, weight: .bold))
              Text("Use \(listing.name == "Home" ? "~" : listing.name)")
            }
          }
          .buttonStyle(PillButton())
          .accessibilityLabel("Use \(listing.name == "Home" ? "~" : listing.name)")
          .frame(maxWidth: .infinity)
          .padding(.horizontal, 20)
          .padding(.bottom, 6)
          .transition(Settle(distance: 20))
        }
      }
      .alert("Rename folder", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
        TextField("Name", text: $newName)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        Button("Rename") { rename() }
        Button("Cancel", role: .cancel) { newName = "" }
      }
      .confirmationDialog(
        "Delete \(deleting?.name ?? "this folder")?",
        isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
        titleVisibility: .visible
      ) {
        Button("Delete folder", role: .destructive) { delete() }
      } message: {
        Text("Everything inside it is deleted from \(link.host.map { $0.kind == .cloud ? "the cloud" : $0.name } ?? "the computer") for good.")
      }
      .alert("Couldn't change that folder", isPresented: Binding(get: { problem != nil && listing != nil }, set: { if !$0 { problem = nil } })) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(problem ?? "")
      }
      .alert("New folder", isPresented: $naming) {
        TextField("Name", text: $newName)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        Button("Create") { create() }
        Button("Cancel", role: .cancel) { newName = "" }
      } message: {
        Text("in \(listing.map { display($0.path) } ?? "this folder")")
      }
    }
    .presentationDetents([.large])
    .presentationBackground(Color.page)
    .sensoryFeedback(.selection, trigger: moved)
    .animation(.ease, value: query.isEmpty)
    .animation(.snappy(duration: 0.2), value: listing?.path == root)
    .task(id: link.host?.id) {
      root = nil
      listing = nil
      cache = [:]
      await go(nil)
    }
    .task(id: query) { await search() }
  }

  // MARK: Pieces

  private var searchField: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(Color.dim)
      TextField(listing.map { "Search in \($0.name == "Home" ? "~" : $0.name)" } ?? "Search", text: $query)
        .font(.geist(16))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .focused($searchFocused)
        .submitLabel(.search)
      if searching { ProgressView().controlSize(.small).tint(Color.dim) }
      if !query.isEmpty {
        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color.faint) }
          .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 14)
    .frame(height: 44)
    .background(Color.white.opacity(0.07), in: .capsule)
  }

  /** ~ › Dev › spark: each part goes back to that folder */
  private func crumbs(_ listing: Listing) -> some View {
    let parts = segments(listing.path)
    return ScrollViewReader { proxy in
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 4) {
          ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
            if i > 0 {
              Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.faint)
            }
            let last = i == parts.count - 1
            Button {
              guard !last else { return }
              Task { await go(part.path) }
            } label: {
              Text(part.name)
                .font(.geistMono(13, last ? .medium : .regular))
                .foregroundStyle(last ? .white : Color.dim)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(last ? Color.white.opacity(0.1) : .clear, in: .capsule)
            }
            .buttonStyle(.plain)
            .id(i)
          }
        }
        .padding(.horizontal, 2)
      }
      .onChange(of: parts.count, initial: true) { proxy.scrollTo(parts.count - 1, anchor: .trailing) }
    }
    .frame(height: 30)
  }

  /** folders recent chats ran in, newest first: picked in one tap */
  private var recent: [String] {
    guard let host = link.host?.id else { return [] }
    var seen = Set<String>()
    return (link.sessions[host] ?? [])
      .sorted { $0.updated > $1.updated }
      .map(\.cwd)
      .filter { !$0.isEmpty && $0 != root && seen.insert($0).inserted }
      .prefix(4)
      .map { $0 }
  }

  private func folderList(_ listing: Listing) -> some View {
    List {
      if listing.path != root, let parent = listing.parent ?? segments(listing.path).dropLast().last?.path {
        Button { Task { await go(parent) } } label: {
          HStack(spacing: 12) {
            Image(systemName: "arrow.turn.left.up")
              .font(.system(size: 14, weight: .semibold))
              .foregroundStyle(Color.dim)
              .frame(width: 22)
            Text(parent == root ? "~" : (parent.split(separator: "/").last.map(String.init) ?? parent))
              .font(.geist(16))
              .foregroundStyle(Color.dim)
              .lineLimit(1)
            Spacer(minLength: 0)
          }
          .padding(.vertical, 12)
          .contentShape(.rect)
        }
        .accessibilityLabel("Up to \(display(parent))")
        .accessibilityIdentifier("folderUp")
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
        .listRowSeparatorTint(Color.hairline)
      }
      if listing.path == root, !recent.isEmpty {
        Section {
          ForEach(recent, id: \.self) { path in
            Button { chosen(path, display(path)) } label: {
              HStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath")
                  .font(.system(size: 14))
                  .foregroundStyle(Color.dim)
                  .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                  Text(path.split(separator: "/").last.map(String.init) ?? path)
                    .font(.geist(16))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                  Text(display(path))
                    .font(.geistMono(11))
                    .foregroundStyle(Color.faint)
                    .lineLimit(1)
                    .truncationMode(.head)
                }
                Spacer(minLength: 0)
                Text("Use")
                  .font(.geist(13, .medium))
                  .foregroundStyle(.white)
                  .padding(.horizontal, 12)
                  .frame(height: 28)
                  .background(Color.white.opacity(0.1), in: .capsule)
              }
              .padding(.vertical, 10)
              .contentShape(.rect)
            }
            .accessibilityLabel("Use \(display(path))")
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            .listRowSeparatorTint(Color.hairline)
          }
        } header: {
          SectionTitle("Recent")
        }
        Section {
          rows(listing)
        } header: {
          SectionTitle("In ~")
        }
      } else {
        rows(listing)
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .overlay {
      if listing.folders.isEmpty, loading == nil {
        Text("No folders in here").font(.geist(15)).foregroundStyle(Color.faint)
      }
    }
    // swipe right from anywhere to go up a level, like the back gesture
    .simultaneousGesture(
      DragGesture(minimumDistance: 30)
        .onEnded { g in
          guard g.translation.width > 90, abs(g.translation.height) < 50, listing.path != root,
                let parent = listing.parent ?? segments(listing.path).dropLast().last?.path else { return }
          Task { await go(parent) }
        }
    )
  }

  @ViewBuilder private func rows(_ listing: Listing) -> some View {
    ForEach(listing.folders) { f in
      Button { Task { await go(f.path) } } label: { FolderRow(name: f.name, detail: nil, git: f.git, loading: loading == f.path) }
        .contextMenu {
          Button("Use this folder", systemImage: "checkmark") { chosen(f.path, display(f.path)) }
          Button("Rename", systemImage: "pencil") {
            newName = f.name
            renaming = f
          }
          Button("Delete", systemImage: "trash", role: .destructive) { deleting = f }
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
        .listRowSeparatorTint(Color.hairline)
    }
  }

  private var searchList: some View {
    List {
      ForEach(results ?? []) { f in
        Button {
          // clear first and resign only after the field has shown the empty text:
          // a field writes its text back as it resigns, which would undo the clear
          query = ""
          Task {
            await go(f.path)
            searchFocused = false
          }
        } label: {
          FolderRow(name: f.name, detail: display(f.path), git: f.git, loading: false)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
        .listRowSeparatorTint(Color.hairline)
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .scrollDismissesKeyboard(.immediately)
    .overlay {
      if results?.isEmpty == true, !searching {
        Text("No folders named “\(query)”").font(.geist(15)).foregroundStyle(Color.faint)
      }
    }
  }

  // MARK: Paths

  private func display(_ path: String) -> String {
    guard let root, path.hasPrefix(root) else { return path }
    let rest = path.dropFirst(root.count)
    return rest.isEmpty ? "~" : "~" + rest
  }

  private func segments(_ path: String) -> [(name: String, path: String)] {
    guard let root, path.hasPrefix(root) else { return [(path, path)] }
    var out: [(String, String)] = [("~", root)]
    var current = root
    for part in path.dropFirst(root.count).split(separator: "/") {
      current += "/" + part
      out.append((String(part), current))
    }
    return out
  }

  // MARK: Loading

  /** shows a folder seen before at once and asks the host again; a new one opens when it answers */
  private func go(_ path: String?) async {
    guard let host = link.host?.id else { return }
    // only the newest tap wins: an answer to an older one just fills the cache
    let ticket = UUID()
    target = ticket
    if let path, let seen = cache[path] {
      listing = seen
      moved += 1
    } else {
      loading = path
    }
    defer { if target == ticket { loading = nil } }
    do {
      let next = try await link.folders(host, path)
      guard link.host?.id == host else { return }
      if root == nil { root = next.path }
      cache[next.path] = next
      guard target == ticket else { return }
      if listing?.path != next.path { moved += 1 }
      listing = next
      problem = nil
    } catch {
      if target == ticket { problem = error.localizedDescription }
    }
  }

  private func search() async {
    let q = query.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty, let host = link.host?.id else {
      results = nil
      return
    }
    try? await Task.sleep(for: .milliseconds(220))
    guard !Task.isCancelled else { return }
    searching = true
    defer { searching = false }
    results = try? await link.search(host, q, in: listing?.path)
  }

  private func rename() {
    guard let f = renaming, let host = link.host?.id else { return }
    let name = newName.trimmingCharacters(in: .whitespaces)
    newName = ""
    guard !name.isEmpty, name != f.name, let here = listing?.path else { return }
    Task {
      do {
        _ = try await link.renameFolder(host, f.path, to: name)
        drop(f.path)
        await go(here)
      } catch {
        problem = error.localizedDescription
      }
    }
  }

  private func delete() {
    guard let f = deleting, let host = link.host?.id, let here = listing?.path else { return }
    Task {
      do {
        try await link.deleteFolder(host, f.path)
        drop(f.path)
        await go(here)
      } catch {
        problem = error.localizedDescription
      }
    }
  }

  /** forgets a folder and everything seen below it */
  private func drop(_ path: String) {
    for key in cache.keys where key == path || key.hasPrefix(path + "/") { cache[key] = nil }
  }

  private func create() {
    guard let listing else { return }
    let name = newName.trimmingCharacters(in: .whitespaces)
    newName = ""
    guard !name.isEmpty, let host = link.host?.id else { return }
    Task {
      do {
        let path = try await link.mkdir(host, in: listing.path, named: name)
        cache[listing.path] = nil
        await go(path)
      } catch {
        problem = error.localizedDescription
      }
    }
  }
}

private struct SectionTitle: View {
  let text: String
  init(_ text: String) { self.text = text }
  var body: some View {
    Text(text)
      .font(.geist(13, .medium))
      .foregroundStyle(Color.faint)
      .textCase(nil)
      .padding(.leading, 4)
  }
}

private struct FolderRow: View {
  let name: String
  let detail: String?
  let git: Bool
  let loading: Bool

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "folder.fill")
        .font(.system(size: 15))
        .foregroundStyle(Color.dim)
        .frame(width: 22)
      VStack(alignment: .leading, spacing: 2) {
        Text(name).font(.geist(16)).foregroundStyle(.white).lineLimit(1)
        if let detail {
          Text(detail).font(.geistMono(11)).foregroundStyle(Color.faint).lineLimit(1).truncationMode(.head)
        }
      }
      Spacer(minLength: 0)
      if git {
        Image(systemName: "arrow.triangle.branch")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(Color.faint)
      }
      if loading {
        ProgressView().controlSize(.mini).tint(Color.dim)
      } else {
        Image(systemName: "chevron.right")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Color.faint)
      }
    }
    .padding(.vertical, 12)
    .contentShape(.rect)
  }
}
