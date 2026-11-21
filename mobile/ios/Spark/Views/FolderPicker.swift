import SwiftUI

/**
 * Choosing where a chat runs: starts at the host's home every time, walks down a folder at a tap,
 * jumps back through the path above, and searches everything below where you are.
 */
struct FolderPicker: View {
  @Environment(Link.self) private var link
  @Environment(\.dismiss) private var dismiss
  /** the chosen folder, and how it reads relative to home */
  let chosen: (String, String) -> Void

  @State private var root: String?
  @State private var listing: Listing?
  @State private var forward = true
  @State private var query = ""
  @State private var results: [Folder]?
  @State private var searching = false
  @State private var problem: String?
  @State private var naming = false
  @State private var newName = ""
  @State private var moved = 0
  @FocusState private var searchFocused: Bool

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        VStack(spacing: 12) {
          HostSwitch()
          searchField
          if query.isEmpty, let listing, listing.path != root { crumbs(listing) }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)

        ZStack {
          if !query.isEmpty {
            searchList.transition(.opacity)
          } else if let listing {
            folderList(listing)
              .id(listing.path)
              .transition(.asymmetric(
                insertion: .offset(x: forward ? 60 : -60).combined(with: .opacity),
                removal: .offset(x: forward ? -60 : 60).combined(with: .opacity)))
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
    .animation(.spring(duration: 0.32, bounce: 0.05), value: listing?.path)
    .animation(.ease, value: query.isEmpty)
    .task(id: link.host?.id) {
      root = nil
      listing = nil
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
              Task { await go(part.path, forward: false) }
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
      if listing.folders.isEmpty {
        Text("No folders in here").font(.geist(15)).foregroundStyle(Color.faint)
      }
    }
  }

  @ViewBuilder private func rows(_ listing: Listing) -> some View {
    ForEach(listing.folders) { f in
      Button { Task { await go(f.path) } } label: { FolderRow(name: f.name, detail: nil, git: f.git) }
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
          FolderRow(name: f.name, detail: display(f.path), git: f.git)
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

  private func go(_ path: String?, forward: Bool = true) async {
    guard let host = link.host?.id else { return }
    do {
      let next = try await link.folders(host, path)
      if root == nil { root = next.path }
      self.forward = forward || (listing.map { next.path.count > $0.path.count } ?? true)
      listing = next
      problem = nil
      moved += 1
    } catch {
      problem = error.localizedDescription
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

  private func create() {
    guard let listing else { return }
    let name = newName.trimmingCharacters(in: .whitespaces)
    newName = ""
    guard !name.isEmpty, let host = link.host?.id else { return }
    Task {
      do {
        let path = try await link.mkdir(host, in: listing.path, named: name)
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
      Image(systemName: "chevron.right")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Color.faint)
    }
    .padding(.vertical, 12)
    .contentShape(.rect)
  }
}
