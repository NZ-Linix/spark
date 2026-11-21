import SwiftUI

extension Color {
  /** the page: true black, so the glass and the bubbles are the only surfaces */
  static let page = Color.black
  /** the user's bubble and other quiet fills */
  static let bubble = Color(white: 0.135)
  static let well = Color(white: 0.08)
  static let hairline = Color.white.opacity(0.08)
  static let dim = Color(white: 0.55)
  static let faint = Color(white: 0.34)
  static let live = Color(red: 0.36, green: 0.86, blue: 0.55)
}

/** The wordmark: the name, set in mono like the terminal it comes from. */
struct Wordmark: View {
  var size: CGFloat = 17

  var body: some View {
    Text("spark")
      .font(.geistMono(size, .medium))
      .kerning(-size * 0.02)
  }
}

/** A small dot that breathes while spark is working. */
struct LiveDot: View {
  var on = true
  @State private var pulse = false

  var body: some View {
    Circle()
      .fill(on ? Color.live : Color.faint)
      .frame(width: 7, height: 7)
      .background {
        if on {
          Circle()
            .fill(Color.live.opacity(0.35))
            .scaleEffect(pulse ? 2.4 : 1)
            .opacity(pulse ? 0 : 1)
        }
      }
      .onAppear {
        guard on else { return }
        withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
      }
      .accessibilityHidden(true)
  }
}

extension View {
  /** a black page under everything, including the bars */
  func page() -> some View {
    background(Color.page.ignoresSafeArea())
  }
}

enum Screen {
  /** the display's corner radius; UIKit knows it but doesn't publish it, so ask quietly and fall back */
  @MainActor static let cornerRadius: CGFloat = {
    let key = ["Radius", "Corner", "display", "_"].reversed().joined()
    guard let screen = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.screen }).first,
          screen.responds(to: NSSelectorFromString(key)),
          let r = screen.value(forKey: key) as? CGFloat, r > 0
    else { return 55 }
    return r
  }()
}

enum Relative {
  static func string(_ date: Date) -> String {
    let s = -date.timeIntervalSinceNow
    if s < 60 { return "now" }
    if s < 3600 { return "\(Int(s / 60))m" }
    if s < 86400 { return "\(Int(s / 3600))h" }
    if s < 7 * 86400 { return "\(Int(s / 86400))d" }
    return date.formatted(.dateTime.day().month(.abbreviated))
  }
}
