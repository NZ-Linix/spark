import SwiftUI

/**
 * Streaming text: the newest glyphs fade and settle in over a short tail, so words appear like ink
 * rather than in chunks. `extra` counts virtual glyphs revealed past the end; once it reaches
 * `length` every glyph is fully drawn and the text renders as usual.
 */
nonisolated struct InkTail: TextRenderer {
  var length: Double = 40
  var extra: Double = .infinity

  func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
    guard extra < length else {
      for line in layout { ctx.draw(line) }
      return
    }
    var total = 0
    for line in layout { for run in line { total += run.count } }
    var i = 0
    for line in layout {
      for run in line {
        for glyph in run {
          let a = min(1, max(0, (Double(total - i) + extra) / length))
          if a >= 1 {
            ctx.draw(glyph)
          } else {
            var c = ctx
            c.opacity = a * a
            c.translateBy(x: 0, y: (1 - a) * 5)
            c.draw(glyph)
          }
          i += 1
        }
      }
    }
  }
}

/**
 * A title that materialises as ordered dither: each glyph's pixels switch on in Bayer order, left to
 * right. Animate `progress` from 0 to 1. Drawn on SwiftUI's render thread, hence nonisolated.
 */
nonisolated struct DitherIn: TextRenderer {
  var progress: Double
  var cell: CGFloat = 2.5

  var animatableData: Double {
    get { progress }
    set { progress = newValue }
  }

  func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
    let glyphs = layout.flatMap { line in line.flatMap { $0 } }
    let n = Double(max(1, glyphs.count))
    for (i, glyph) in glyphs.enumerated() {
      let t = min(1, max(0, (progress - Double(i) / n * 0.45) / 0.55))
      if t >= 1 {
        ctx.draw(glyph)
        continue
      }
      guard t > 0 else { continue }
      let b = glyph.typographicBounds.rect.insetBy(dx: -2, dy: -4)
      var mask = Path()
      var row = Int((b.minY / cell).rounded(.down))
      while CGFloat(row) * cell < b.maxY {
        var col = Int((b.minX / cell).rounded(.down))
        while CGFloat(col) * cell < b.maxX {
          if Bayer.threshold(col, row) < t { mask.addRect(CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell, width: cell, height: cell)) }
          col += 1
        }
        row += 1
      }
      var c = ctx
      c.clip(to: mask)
      c.draw(glyph)
    }
  }
}

/** 4×4 Bayer matrix: ordered-dither thresholds, so a smooth value becomes a crisp pixel pattern. */
nonisolated enum Bayer {
  private static let m: [Double] = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5].map { ($0 + 0.5) / 16 }
  static func threshold(_ col: Int, _ row: Int) -> Double { m[(row & 3) * 4 + (col & 3)] }
}

/** A highlight sweeping across text that is waiting on something. */
struct Shimmer: ViewModifier {
  func body(content: Content) -> some View {
    TimelineView(.animation) { timeline in
      let t = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
      let x = t * 2.4 - 0.7
      content.foregroundStyle(
        LinearGradient(
          stops: [
            .init(color: .secondary.opacity(0.75), location: 0),
            .init(color: .primary, location: 0.5),
            .init(color: .secondary.opacity(0.75), location: 1),
          ],
          startPoint: UnitPoint(x: x - 0.4, y: 0.5),
          endPoint: UnitPoint(x: x + 0.4, y: 0.5)))
    }
  }
}

/** New questions rise out of the composer: up, unblurring, settling into place. */
struct Rise: Transition {
  func body(content: Content, phase: TransitionPhase) -> some View {
    content
      .opacity(phase.isIdentity ? 1 : 0)
      .blur(radius: phase.isIdentity ? 0 : 12)
      .offset(y: phase == .willAppear ? 64 : phase == .didDisappear ? -20 : 0)
      .scaleEffect(phase.isIdentity ? 1 : 0.97, anchor: .bottom)
  }
}

/**
 * A sent message leaving the composer: it starts low and a little small at the right, where the
 * send button is, and springs up into its place while it sharpens.
 */
struct Sent: Transition {
  func body(content: Content, phase: TransitionPhase) -> some View {
    content
      .opacity(phase.isIdentity ? 1 : 0)
      .blur(radius: phase == .willAppear ? 4 : 0)
      .scaleEffect(phase.isIdentity ? 1 : 0.88, anchor: .bottomTrailing)
      .offset(y: phase == .willAppear ? 44 : 0)
  }
}

/** Small things arriving: a soft fade up out of a blur. */
struct Settle: Transition {
  var distance: CGFloat = 10

  func body(content: Content, phase: TransitionPhase) -> some View {
    content
      .opacity(phase.isIdentity ? 1 : 0)
      .blur(radius: phase.isIdentity ? 0 : 6)
      .offset(y: phase.isIdentity ? 0 : distance)
  }
}

extension Animation {
  static let ease = Animation.spring(duration: 0.45, bounce: 0.12)
}
