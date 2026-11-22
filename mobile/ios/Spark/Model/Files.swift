import Foundation

/** One thing in a folder, as the chat's file browser lists it. */
nonisolated struct FileEntry: Codable, Identifiable, Hashable, Sendable {
  var name: String
  var path: String
  var dir: Bool
  /** in bytes; files only */
  var size: Int?

  var id: String { path }
  var hidden: Bool { name.hasPrefix(".") }
}

nonisolated struct FileListing: Codable, Sendable {
  var path: String
  var name: String
  var entries: [FileEntry]
}

/** A file to show: text cut at the host's limit, an image whole, or only its name and size. */
nonisolated struct FileContent: Codable, Sendable {
  enum Kind: String, Codable, Sendable { case text, image, binary }
  var path: String
  var name: String
  var size: Int
  var kind: Kind
  var text: String?
  var data: String?
  var truncated: Bool?
  /** when it last changed on the host, in ms; a save sends it back */
  var modified: Double
}

/** one piece of a file's bytes */
nonisolated struct FilePiece: Codable, Sendable {
  var name: String
  var size: Int
  var offset: Int
  var data: String
}

nonisolated struct SavedFile: Codable, Sendable {
  var size: Int
  var modified: Double
}

extension Link {
  func files(_ host: String, _ path: String) async throws -> FileListing {
    try await request(host, "files", ["path": .string(path)], as: FileListing.self)
  }

  func file(_ host: String, _ path: String) async throws -> FileContent {
    try await request(host, "file", ["path": .string(path)], as: FileContent.self)
  }

  /** fails when the file changed on the host after `modified`, so the phone never saves over newer work */
  func saveFile(_ host: String, _ path: String, text: String, modified: Double) async throws -> SavedFile {
    try await request(host, "fileWrite", ["path": .string(path), "text": .string(text), "modified": .number(modified)], as: SavedFile.self)
  }

  /** a new empty file, or a folder; returns its path */
  func createEntry(_ host: String, in folder: String, name: String, dir: Bool) async throws -> String {
    try await request(host, "fileCreate", ["path": .string(folder), "name": .string(name), "dir": .bool(dir)], as: String.self)
  }

  /** returns the new path */
  func renameEntry(_ host: String, _ path: String, to name: String) async throws -> String {
    try await request(host, "entryRename", ["path": .string(path), "name": .string(name)], as: String.self)
  }

  func deleteEntry(_ host: String, _ path: String) async throws {
    _ = try await request(host, "entryDelete", ["path": .string(path)])
  }

  /**
   * A copy of a file on the phone, fetched a piece at a time, in a folder of its own under the
   * temporary directory so it keeps the file's name. `progress` runs from 0 to 1.
   */
  func download(_ host: String, _ path: String, progress: (Double) -> Void) async throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "downloads/\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var url: URL?
    var handle: FileHandle?
    defer { try? handle?.close() }
    var offset = 0
    var size = 0
    repeat {
      try Task.checkCancellation()
      let piece = try await request(host, "fileData", ["path": .string(path), "offset": .number(Double(offset))], as: FilePiece.self)
      guard let bytes = Data(base64Encoded: piece.data) else { throw LinkError("The file came through damaged.") }
      if handle == nil {
        let file = dir.appending(path: piece.name)
        FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: nil)
        handle = try FileHandle(forWritingTo: file)
        url = file
      }
      try handle?.write(contentsOf: bytes)
      size = piece.size
      offset += bytes.count
      progress(size == 0 ? 1 : Double(offset) / Double(size))
      if bytes.isEmpty { break }
    } while offset < size
    guard let url else { throw LinkError("The file came through empty.") }
    return url
  }
}

/**
 * A terminal in a chat's folder. Each command runs on its own in the host's login shell and streams
 * back; a `cd` carries over to the next one. It lives as long as the chat's screen, so closing the
 * terminal and opening it again keeps what ran and what's still running.
 */
@Observable
final class Terminal: Identifiable {
  struct Block: Identifiable {
    let id: String
    /** where it ran */
    let cwd: String
    let command: String
    var output = ""
    var code: Int?
    var running = true
  }

  let host: String
  /** the chat's folder, where the terminal starts */
  let root: String
  private(set) var cwd: String
  private(set) var blocks: [Block] = []

  /** what one command keeps on the phone; older output gives way */
  private static let keep = 200_000

  init(host: String, root: String) {
    self.host = host
    self.root = root
    cwd = root
  }

  var running: Bool { blocks.last?.running == true }

  func run(_ typed: String, on link: Link) {
    let command = Self.plain(typed).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !command.isEmpty, !running else { return }
    if command == "clear" {
      blocks.removeAll()
      return
    }
    let id = UUID().uuidString
    blocks.append(Block(id: id, cwd: cwd, command: command))
    // registered before the request: output can arrive ahead of the reply
    link.terms[id] = { [weak self] e in self?.receive(id, e) }
    Task {
      do {
        _ = try await link.request(host, "run", ["run": .string(id), "cwd": .string(cwd), "command": .string(command)])
      } catch {
        link.terms[id] = nil
        finish(id, code: -1, cwd: nil, note: error.localizedDescription)
      }
    }
  }

  func stop(on link: Link) {
    guard let block = blocks.last, block.running else { return }
    let id = block.id
    Task {
      _ = try? await link.request(host, "runStop", ["run": .string(id)])
      // the host's word that it ended can be lost with the connection; don't spin forever
      try? await Task.sleep(for: .seconds(3))
      if blocks.last?.id == id, blocks.last?.running == true {
        link.terms[id] = nil
        finish(id, code: 130, cwd: nil, note: nil)
      }
    }
  }

  func clear() {
    blocks.removeAll { !$0.running }
  }

  private func receive(_ id: String, _ e: Event) {
    guard let i = blocks.firstIndex(where: { $0.id == id }) else { return }
    if let data = e.data { blocks[i].output = Self.append(data, to: blocks[i].output) }
    if e.done == true { finish(id, code: e.code ?? 0, cwd: e.cwd, note: nil) }
  }

  private func finish(_ id: String, code: Int, cwd next: String?, note: String?) {
    guard let i = blocks.firstIndex(where: { $0.id == id }) else { return }
    if let note { blocks[i].output += (blocks[i].output.isEmpty || blocks[i].output.hasSuffix("\n") ? "" : "\n") + note }
    blocks[i].code = code
    blocks[i].running = false
    if let next { cwd = next }
  }

  /**
   * Output as a terminal would leave it: colour codes dropped, and a carriage return writes over its
   * line, so a progress bar shows its latest state instead of every step.
   */
  static func append(_ chunk: String, to output: String) -> String {
    var out = output
    let clean = chunk.replacing(ansi, with: "").replacingOccurrences(of: "\r\n", with: "\n")
    for (n, part) in clean.split(separator: "\r", omittingEmptySubsequences: false).enumerated() {
      if n > 0, let line = out.lastIndex(of: "\n") {
        out.removeSubrange(out.index(after: line)...)
      } else if n > 0 {
        out = ""
      }
      out += part
    }
    if out.utf8.count > keep {
      out = String(out.suffix(keep * 3 / 4))
      if let line = out.firstIndex(of: "\n") { out = String(out[out.index(after: line)...]) }
    }
    return out
  }

  /** the keyboard's typographer undone: a shell wants straight quotes and two hyphens */
  static func plain(_ s: String) -> String {
    var s = s
    for (from, to) in [("\u{201C}", "\""), ("\u{201D}", "\""), ("\u{201E}", "\""), ("\u{2018}", "'"), ("\u{2019}", "'"), ("\u{2014}", "--"), ("\u{2026}", "...")] {
      s = s.replacingOccurrences(of: from, with: to)
    }
    return s
  }

  private nonisolated(unsafe) static let ansi = /\x{1B}(?:\[[0-9;?]*[ -\/]*[@-~]|\][^\x{07}\x{1B}]*(?:\x{07}|\x{1B}\\)|[()][A-Za-z0-9]|[=>78])/
}
