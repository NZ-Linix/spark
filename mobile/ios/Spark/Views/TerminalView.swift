import SwiftUI

/** A terminal in the chat's folder: type a command, see what it prints, stop it if it runs long. */
struct TerminalView: View {
  @Environment(Link.self) private var link
  @Environment(\.dismiss) private var dismiss
  let terminal: Terminal
  @State private var input = ""
  @FocusState private var focused: Bool

  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 18) {
          ForEach(terminal.blocks) { b in
            BlockView(block: b, last: b.id == terminal.blocks.last?.id) {
              input = b.command
              focused = true
            }
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .defaultScrollAnchor(.bottom)
      .defaultScrollAnchor(.bottom, for: .sizeChanges)
      .scrollDismissesKeyboard(.interactively)
      .safeAreaInset(edge: .bottom, spacing: 0) { field }
      .page()
      .navigationTitle(FilesView.name(terminal.cwd))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Close", systemImage: "xmark") { dismiss() }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("Clear", systemImage: "eraser") { withAnimation(.smooth(duration: 0.25)) { terminal.clear() } }
            .disabled(terminal.blocks.allSatisfy(\.running))
        }
      }
    }
    .tint(.white)
    .presentationDetents([.large])
    .presentationBackground(Color.page)
    .onAppear { focused = true }
    .sensoryFeedback(trigger: terminal.blocks.last?.running) { was, now in
      guard was == true, now == false else { return nil }
      return terminal.blocks.last?.code == 0 ? .impact(flexibility: .soft, intensity: 0.5) : .warning
    }
  }

  private var field: some View {
    Composer(
      text: $input, focused: $focused, running: terminal.running, enabled: link.phase == .online,
      placeholder: "Command", working: "Running\u{2026}", command: true
    ) {
      run()
    } stop: {
      terminal.stop(on: link)
    }
  }

  private func run() {
    guard !terminal.running else { return }
    let command = input
    guard !command.trimmingCharacters(in: .whitespaces).isEmpty else { return }
    input = ""
    terminal.run(command, on: link)
    focused = true
  }
}

private struct BlockView: View {
  let block: Terminal.Block
  let last: Bool
  /** puts the command back in the field */
  let again: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 7) {
        Text(FilesView.name(block.cwd)).foregroundStyle(Color.faint)
        Text("\u{276F}").foregroundStyle(Color(red: 0.36, green: 0.86, blue: 0.55))
        Text(block.command).foregroundStyle(.white)
      }
      .font(.geistMono(13, .medium))
      .contentShape(.rect)
      .onTapGesture(perform: again)
      .accessibilityAddTraits(.isButton)
      .accessibilityHint("Puts the command back in the field")

      let output = block.output.hasSuffix("\n") ? String(block.output.dropLast()) : block.output
      if !output.isEmpty {
        Text(output)
          .font(.geistMono(12))
          .foregroundStyle(Color(white: 0.78))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      if block.running {
        Cursor()
      } else if let code = block.code, code != 0 {
        Text(code == 130 ? "stopped" : "exit \(code)")
          .font(.geistMono(11))
          .foregroundStyle(Color(red: 0.95, green: 0.45, blue: 0.42))
      }
    }
    .transition(.opacity.combined(with: .offset(y: 6)))
  }
}

/** a block cursor that breathes while a command runs */
private struct Cursor: View {
  @State private var on = false

  var body: some View {
    RoundedRectangle(cornerRadius: 1.5)
      .fill(Color(white: 0.7))
      .frame(width: 8, height: 14)
      .opacity(on ? 0.15 : 0.9)
      .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: on)
      .onAppear { on = true }
  }
}
