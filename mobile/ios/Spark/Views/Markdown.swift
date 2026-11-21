import SwiftUI

/** The block structure of an answer. Parsed again as text streams in, so unfinished blocks must read well too. */
enum Block: Hashable {
  case heading(Int, String)
  case paragraph(String)
  case item(level: Int, marker: String, String)
  case quote(String)
  case code(lang: String, String)
  case table([String], [[String]])
  case rule

  static func parse(_ text: String) -> [Block] {
    var out: [Block] = []
    var para: [String] = []
    let lines = text.components(separatedBy: "\n")
    var i = 0

    func flush() {
      if !para.isEmpty { out.append(.paragraph(para.joined(separator: " "))) }
      para = []
    }

    while i < lines.count {
      let line = lines[i]
      let t = line.trimmingCharacters(in: .whitespaces)

      if t.hasPrefix("```") || t.hasPrefix("~~~") {
        flush()
        let fence = String(t.prefix(3))
        let info = t.dropFirst(3).trimmingCharacters(in: .whitespaces)
        let lang = info.split(separator: " ").first.map { $0.lowercased() } ?? ""
        var body: [String] = []
        i += 1
        while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
          body.append(lines[i])
          i += 1
        }
        i += 1
        let code = body.joined(separator: "\n")
        out.append(.code(lang: lang, code))
        continue
      }

      if t.isEmpty {
        flush()
        i += 1
        continue
      }

      if let m = t.firstMatch(of: /^(#{1,6})\s+(.*)$/) {
        flush()
        out.append(.heading(m.1.count, String(m.2).replacing(/\s#+$/, with: "")))
        i += 1
        continue
      }

      if t.wholeMatch(of: /(\*\s*){3,}|(-\s*){3,}|(_\s*){3,}/) != nil {
        flush()
        out.append(.rule)
        i += 1
        continue
      }

      if t.hasPrefix("|"), i + 1 < lines.count, lines[i + 1].trimmingCharacters(in: .whitespaces).wholeMatch(of: /\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?/) != nil {
        flush()
        let head = cells(t)
        var rows: [[String]] = []
        i += 2
        while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
          rows.append(cells(lines[i]))
          i += 1
        }
        out.append(.table(head, rows))
        continue
      }

      if let m = line.firstMatch(of: /^(\s*)([-*+•]|\d{1,3}[.)])\s+(.*)$/) {
        flush()
        var body = String(m.3)
        i += 1
        // lazy continuation lines belong to the item
        while i < lines.count {
          let next = lines[i]
          let nt = next.trimmingCharacters(in: .whitespaces)
          if nt.isEmpty || next.firstMatch(of: /^\s*([-*+•]|\d{1,3}[.)])\s+/) != nil || nt.hasPrefix("#") || nt.hasPrefix("```") || nt.hasPrefix("|") || nt.hasPrefix(">") { break }
          body += " " + nt
          i += 1
        }
        let level = m.1.replacingOccurrences(of: "\t", with: "    ").count / 2
        out.append(.item(level: min(level, 4), marker: String(m.2), body))
        continue
      }

      if t.hasPrefix(">") {
        flush()
        var body: [String] = []
        while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
          body.append(lines[i].trimmingCharacters(in: .whitespaces).dropFirst().trimmingCharacters(in: .whitespaces))
          i += 1
        }
        out.append(.quote(body.joined(separator: " ")))
        continue
      }

      para.append(t)
      i += 1
    }
    flush()
    return out
  }

  private static func cells(_ line: String) -> [String] {
    var s = line.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("|") { s.removeFirst() }
    if s.hasSuffix("|") { s.removeLast() }
    return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
  }
}

/** Inline Markdown: bold, italics, code and links. */
enum Inline {
  static func render(_ s: String) -> AttributedString {
    var out =
      (try? AttributedString(
        markdown: s,
        options: .init(allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)))
      ?? AttributedString(s)
    for run in out.runs where run.inlinePresentationIntent?.contains(.code) == true {
      out[run.range].font = .geistMono(15, relativeTo: .body)
      out[run.range].backgroundColor = Color.white.opacity(0.08)
    }
    return out
  }

  static func plain(_ s: String) -> String {
    s.replacing(/\*\*(.+?)\*\*/) { String($0.1) }.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

struct MarkdownView: View {
  let text: String
  /** while streaming: how far the last block's fade-in has got (see InkTail) */
  var ink: Double?

  var body: some View {
    let blocks = Block.parse(text)
    VStack(alignment: .leading, spacing: 14) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { i, block in
        BlockView(block: block, ink: i == blocks.count - 1 ? ink : nil)
          .equatable()
          .transition(Settle(distance: 6))
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .animation(.smooth(duration: 0.35), value: blocks.count)
  }
}

/** One block; equatable, so finished blocks aren't re-rendered while the last one streams. */
private struct BlockView: View, Equatable {
  let block: Block
  let ink: Double?

  private var renderer: InkTail { InkTail(extra: ink ?? .infinity) }

  var body: some View {
    switch block {
    case .heading(let level, let s):
      Text(Inline.render(s))
        .font(.geist(level <= 2 ? 21 : 18, .semibold, relativeTo: level <= 2 ? .title3 : .headline))
        .kerning(-0.2)
        .textRenderer(renderer)
        .padding(.top, 6)
    case .paragraph(let s):
      Text(Inline.render(s))
        .font(.geist(17))
        .lineSpacing(5)
        .textRenderer(renderer)
    case .item(let level, let marker, let s):
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text(marker.first?.isNumber == true ? marker.replacingOccurrences(of: ")", with: ".") : "•")
          .font(.geist(17, marker.first?.isNumber == true ? .medium : .regular).monospacedDigit())
          .foregroundStyle(.secondary)
          .frame(minWidth: 14, alignment: .leading)
        Text(Inline.render(s))
          .font(.geist(17))
          .lineSpacing(5)
          .textRenderer(renderer)
      }
      .padding(.leading, CGFloat(level) * 20)
    case .quote(let s):
      Text(Inline.render(s))
        .font(.geist(17))
        .foregroundStyle(.secondary)
        .textRenderer(renderer)
        .padding(.leading, 14)
        .overlay(alignment: .leading) { Capsule().fill(.tertiary).frame(width: 3) }
    case .code(let lang, let code):
      CodeBlock(label: CodeBlock.name(lang), code: code)
    case .table(let head, let rows):
      TableBlock(head: head, rows: rows)
    case .rule:
      Divider().padding(.vertical, 4)
    }
  }
}

struct CopyButton: View {
  let text: String
  var label = "Copy"
  @State private var copied = false

  var body: some View {
    Button {
      UIPasteboard.general.string = text
      copied = true
      Task {
        try? await Task.sleep(for: .seconds(1.4))
        copied = false
      }
    } label: {
      // sized to the larger of both states, so swapping to the checkmark doesn't nudge anything beside it
      Label {
        ZStack(alignment: .leading) {
          Text(label).hidden()
          Text("Copied").hidden()
          Text(copied ? "Copied" : label)
        }
      } icon: {
        ZStack {
          Image(systemName: "doc.on.doc").hidden()
          Image(systemName: "checkmark").hidden()
          Image(systemName: copied ? "checkmark" : "doc.on.doc")
            .contentTransition(.symbolEffect(.replace))
        }
      }
      .accessibilityLabel(copied ? "Copied" : label)
    }
    .sensoryFeedback(.success, trigger: copied) { _, new in new }
  }
}

private struct CodeBlock: View {
  let label: String
  let code: String

  static func name(_ lang: String) -> String {
    let names = [
      "js": "JavaScript", "javascript": "JavaScript", "ts": "TypeScript", "typescript": "TypeScript", "tsx": "TSX", "jsx": "JSX",
      "py": "Python", "python": "Python", "rb": "Ruby", "sh": "Shell", "bash": "Bash", "zsh": "Zsh", "swift": "Swift", "kt": "Kotlin",
      "go": "Go", "rs": "Rust", "rust": "Rust", "c": "C", "cpp": "C++", "cs": "C#", "java": "Java", "php": "PHP", "sql": "SQL",
      "html": "HTML", "css": "CSS", "json": "JSON", "yaml": "YAML", "yml": "YAML", "toml": "TOML", "md": "Markdown", "markdown": "Markdown",
      "xml": "XML", "dockerfile": "Dockerfile", "graphql": "GraphQL", "lua": "Lua", "r": "R",
    ]
    return names[lang] ?? (lang.isEmpty ? "Code" : lang.capitalized)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text(label).font(.geist(13, .medium)).foregroundStyle(.secondary)
        Spacer()
        CopyButton(text: code)
          .labelStyle(.iconOnly)
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 14)
      .padding(.top, 10)
      ScrollView(.horizontal, showsIndicators: false) {
        Text(code)
          .font(.geistMono(14, relativeTo: .footnote))
          .lineSpacing(3)
          .textSelection(.enabled)
          .padding(14)
      }
    }
    .background(Color.white.opacity(0.06), in: .rect(cornerRadius: 16, style: .continuous))
  }
}

private struct TableBlock: View {
  let head: [String]
  let rows: [[String]]

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
        GridRow {
          ForEach(Array(head.enumerated()), id: \.offset) { _, cell in
            cellText(cell).font(.geist(15, .semibold))
          }
        }
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
          Divider().gridCellUnsizedAxes(.horizontal)
          GridRow {
            ForEach(0..<head.count, id: \.self) { c in
              cellText(c < row.count ? row[c] : "").font(.geist(15))
            }
          }
        }
      }
      .padding(.vertical, 4)
    }
  }

  private func cellText(_ s: String) -> some View {
    Text(Inline.render(s))
      .frame(maxWidth: 240, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
  }
}
