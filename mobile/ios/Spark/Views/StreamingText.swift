import SwiftUI

/**
 * The answer as it streams. Text arrives from the network in uneven bursts; this reveals it at a
 * steady pace that speeds up when it falls behind, and fades in the newest glyphs.
 */
struct StreamingText: View {
  let text: String
  let streaming: Bool

  private static let tail = 40
  @State private var shown: Int

  init(text: String, streaming: Bool) {
    self.text = text
    self.streaming = streaming
    // an answer that's already complete (reopened later) shows at once
    _shown = State(initialValue: streaming ? 0 : text.count + Self.tail)
  }

  private struct Key: Equatable {
    var count: Int
    var streaming: Bool
  }

  var body: some View {
    let count = text.count
    let extra = Double(max(0, shown - count))
    let settled = !streaming && extra >= Double(Self.tail)
    let visible = shown >= count ? text : String(text.prefix(shown))
    MarkdownView(text: settled ? visible : Streaming.tidy(visible), ink: settled ? nil : extra)
      .task(id: Key(count: count, streaming: streaming)) { await reveal() }
  }

  private func reveal() async {
    while !Task.isCancelled {
      let count = text.count
      // a reset (the model retried) shortens the text
      if shown > count + Self.tail { shown = count }
      let end = streaming ? count : count + Self.tail
      guard shown < end else { return }
      let behind = count - shown
      let step = behind > 0 ? max(1, Int((Double(behind) / 10).rounded(.up))) : 2
      shown = min(end, shown + step)
      try? await Task.sleep(for: .milliseconds(16))
    }
  }
}

/** Makes half-streamed Markdown read well: no stray markers, tables and formulas only once whole. */
enum Streaming {
  static func tidy(_ s: String) -> String {
    var lines = s.components(separatedBy: "\n")
    let isRow = { (l: String) in l.trimmingCharacters(in: .whitespaces).hasPrefix("|") }

    // a table row shows once its line is complete, and a table once its header rule is in
    if let last = lines.last, isRow(last) { lines.removeLast() }
    if let last = lines.last, isRow(last), lines.count < 2 || !isRow(lines[lines.count - 2]) { lines.removeLast() }

    var out = lines.joined(separator: "\n")

    // inside an unfinished code block everything is literal
    if out.components(separatedBy: "```").count % 2 == 0 { return out }

    // close emphasis and code left open in the last paragraph, so bold turns bold as it's typed
    if out.hasSuffix("*"), !out.hasSuffix("**") { out.removeLast() }
    let para = out.range(of: "\n\n", options: .backwards).map { String(out[$0.upperBound...]) } ?? out
    if (para.components(separatedBy: "**").count - 1) % 2 == 1 {
      if out.hasSuffix("**") { out.removeLast(2) } else { out += "**" }
    }
    if (para.filter { $0 == "`" }.count) % 2 == 1 {
      if out.hasSuffix("`") { out.removeLast() } else { out += "`" }
    }
    return out
  }
}
