import SwiftUI

/** Pairing a Mac from Settings or the host menu. */
struct PairView: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      PairPanel(title: "Pair a Mac") { dismiss() }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .page()
        .toolbar {
          ToolbarItem(placement: .topBarLeading) {
            Button("Close", systemImage: "xmark") { dismiss() }
          }
        }
    }
  }
}

/** Type the six digits `spark pair` shows on the Mac. Used on the first screen and in the sheet. */
struct PairPanel: View {
  @Environment(Link.self) private var link
  let title: String
  let done: () -> Void
  @State private var code = ""
  @State private var busy = false
  @State private var problem: String?
  @State private var failed = 0
  @State private var paired: HostEntry?
  var body: some View {
    ZStack {
      form
        .opacity(paired == nil ? 1 : 0)
        .scaleEffect(paired == nil ? 1 : 0.96)
        .blur(radius: paired == nil ? 0 : 8)
        .allowsHitTesting(paired == nil)
      if let paired {
        VStack(spacing: 14) {
          Image(systemName: "checkmark")
            .font(.system(size: 34, weight: .semibold))
            .frame(width: 76, height: 76)
            .glassEffect(.regular, in: .circle)
          Text("Paired with \(paired.name)")
            .font(.geist(22, .semibold))
        }
        .transition(.scale(0.85).combined(with: .opacity))
      }
    }
    .animation(.spring(duration: 0.5, bounce: 0.2), value: paired)
    .animation(.ease, value: problem)
    .sensoryFeedback(.error, trigger: failed)
    .sensoryFeedback(.success, trigger: paired) { _, new in new != nil }
    .onChange(of: code) { _, new in
      let digits = String(new.filter(\.isNumber).prefix(6))
      if digits != new { code = digits }
      if digits.count == 6 { submit(digits) }
      if !digits.isEmpty { problem = nil }
    }
  }

  private var form: some View {
    VStack(spacing: 28) {
        VStack(spacing: 12) {
          Text(title)
            .font(.geist(26, .semibold))
            .kerning(-0.5)
          HStack(spacing: 6) {
            Text("On your Mac, run")
            Text("spark pair")
              .font(.geistMono(14, .medium))
              .foregroundStyle(.white)
              .padding(.horizontal, 8)
              .padding(.vertical, 4)
              .background(Color.white.opacity(0.08), in: .rect(cornerRadius: 8, style: .continuous))
          }
          .font(.geist(15))
          .foregroundStyle(Color.dim)
          Text("then type the code it shows.")
            .font(.geist(15))
            .foregroundStyle(Color.dim)
        }
        .multilineTextAlignment(.center)

        CodeBoxes(code: code, busy: busy)
          .modifier(Shake(count: failed))
          .contextMenu {
            Button("Paste", systemImage: "doc.on.clipboard") {
              code = String((UIPasteboard.general.string ?? "").filter(\.isNumber).prefix(6))
            }
          }

        Text(problem ?? " ")
          .font(.geist(14))
          .foregroundStyle(Color.dim)
          .multilineTextAlignment(.center)
          .lineLimit(2, reservesSpace: false)
          .frame(height: 20)
          .opacity(problem == nil ? 0 : 1)
          .contentTransition(.opacity)
          .padding(.vertical, -10)

        Keypad(enabled: !busy) { key in
          switch key {
          case .digit(let d): if code.count < 6 { code.append(d) }
          case .delete: if !code.isEmpty { code.removeLast() }
          }
        }
        .padding(.top, 4)
    }
  }

  private func submit(_ digits: String) {
    guard !busy else { return }
    busy = true
    Task {
      defer { busy = false }
      do {
        paired = try await link.pair(digits)
        try? await Task.sleep(for: .seconds(1.2))
        link.finishOnboarding()
        done()
      } catch {
        problem = error.localizedDescription
        withAnimation(.linear(duration: 0.42)) { failed += 1 }
        try? await Task.sleep(for: .milliseconds(450))
        code = ""
      }
    }
  }
}

/** The six digits typed so far, with a caret on the next one. */
private struct CodeBoxes: View {
  let code: String
  let busy: Bool

  var body: some View {
    HStack(spacing: 8) {
      ForEach(0..<6, id: \.self) { i in
        box(i)
        if i == 2 {
          Capsule().fill(Color.faint).frame(width: 8, height: 2)
        }
      }
    }
    .opacity(busy ? 0.5 : 1)
    .animation(.spring(duration: 0.3, bounce: 0.3), value: code)
    .accessibilityElement()
    .accessibilityLabel("Pairing code")
    .accessibilityValue(code.map(String.init).joined(separator: " "))
  }

  private func box(_ i: Int) -> some View {
    let chars = Array(code)
    let current = i == chars.count
    return ZStack {
      if i < chars.count {
        Text(String(chars[i]))
          .font(.geistMono(26, .medium))
          .transition(.scale(0.5).combined(with: .opacity))
      } else if current {
        Caret()
      }
    }
    .frame(width: 46, height: 58)
    .glassEffect(.regular, in: .rect(cornerRadius: 14))
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(Color.white.opacity(current ? 0.5 : 0), lineWidth: 1)
    }
  }
}

/** A number pad drawn in the app, so there's no system keyboard and no empty bar above it. */
private struct Keypad: View {
  enum Key { case digit(Character), delete }
  let enabled: Bool
  let press: (Key) -> Void
  @State private var taps = 0

  private let rows: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["", "0", "⌫"]]

  var body: some View {
    VStack(spacing: 12) {
      ForEach(rows, id: \.self) { row in
        HStack(spacing: 22) {
          ForEach(row, id: \.self) { key in
            if key.isEmpty {
              Color.clear.frame(width: 72, height: 72)
            } else {
              Button {
                taps += 1
                press(key == "⌫" ? .delete : .digit(Character(key)))
              } label: {
                Group {
                  if key == "⌫" {
                    Image(systemName: "delete.left").font(.system(size: 20, weight: .medium))
                  } else {
                    Text(key).font(.geistMono(28, .regular))
                  }
                }
                .foregroundStyle(.white)
                .frame(width: 72, height: 72)
                .contentShape(.circle)
              }
              .buttonStyle(KeyStyle(glass: key != "⌫"))
              .accessibilityLabel(key == "⌫" ? "Delete" : key)
            }
          }
        }
      }
    }
    .disabled(!enabled)
    .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: taps)
  }
}

private struct KeyStyle: ButtonStyle {
  let glass: Bool
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background {
        if glass { Circle().fill(Color.white.opacity(configuration.isPressed ? 0.22 : 0.08)) }
      }
      .scaleEffect(configuration.isPressed ? 0.94 : 1)
      .animation(.spring(duration: 0.2, bounce: 0.3), value: configuration.isPressed)
  }
}

private struct Caret: View {
  @State private var on = true
  var body: some View {
    Capsule()
      .fill(.white)
      .frame(width: 2, height: 24)
      .opacity(on ? 1 : 0)
      .onAppear { withAnimation(.easeInOut(duration: 0.55).repeatForever()) { on = false } }
  }
}
