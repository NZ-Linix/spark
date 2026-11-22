import SwiftUI

/**
 * The answer as it streams. Text arrives from the network in uneven bursts; this reveals it at a
 * steady pace that speeds up when it falls behind, and fades in the newest glyphs.
 */
struct StreamingText: View {
  let text: String
  let streaming: Bool

  private static let tail = 40
  /** characters revealed so far */
  @State private var shown: Int
  /** how far the newest characters have inked in, 0 to `tail` */
  @State private var ink: Int

  init(text: String, streaming: Bool) {
    self.text = text
    self.streaming = streaming
    // an answer that's already complete (reopened later) shows at once
    _shown = State(initialValue: streaming ? 0 : text.count)
    _ink = State(initialValue: streaming ? 0 : Self.tail)
  }

  private struct Key: Equatable {
    var count: Int
    var streaming: Bool
  }

  var body: some View {
    let count = text.count
    let caught = shown >= count && ink >= Self.tail
    let settled = !streaming && caught
    let visible = shown >= count ? text : String(text.prefix(shown))
    MarkdownView(text: settled ? visible : Streaming.tidy(visible), ink: caught ? nil : Double(ink))
      .task(id: Key(count: count, streaming: streaming)) { await reveal() }
  }

  /**
   * Reveals text and inks in the tail on its own clock. Once the text is all shown the tail finishes
   * inking even while the turn is still open, so a reply never sits half-faded waiting for the end.
   */
  private func reveal() async {
    while !Task.isCancelled {
      let count = text.count
      // a reset (the model retried) shortens the text
      if shown > count { shown = count }
      guard shown < count || ink < Self.tail else { return }
      if shown < count {
        // about 30 steps a second: each one parses the answer again, so fewer, larger steps stay smooth
        let step = max(2, Int((Double(count - shown) / 6).rounded(.up)))
        shown = min(count, shown + step)
        // the tail slides along with the text: a glyph already inked doesn't fade back
        ink = max(0, ink - step)
      } else {
        ink = min(Self.tail, ink + 4)
      }
      try? await Task.sleep(for: .milliseconds(33))
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
