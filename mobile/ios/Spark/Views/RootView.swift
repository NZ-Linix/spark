import SwiftUI

struct RootView: View {
  @Environment(Link.self) private var link

  var body: some View {
    ZStack {
      if link.ready && link.registered {
        Shell()
          .transition(.opacity)
      } else {
        WelcomeView()
          .transition(.opacity.combined(with: .scale(0.98)))
      }
    }
    .animation(.ease, value: link.ready && link.registered)
    .page()
  }
}

/** First launch: the name, then straight into pairing. */
private struct WelcomeView: View {
  @Environment(Link.self) private var link
  @State private var shown = false
  @State private var joining = false
  @State private var problem: String?

  var body: some View {
    VStack(spacing: 0) {
      Spacer(minLength: 16)
      Text("spark")
        .font(.geistMono(44, .medium))
        .kerning(-1)
        .textRenderer(DitherIn(progress: shown ? 1 : 0))
      Spacer(minLength: 20)
      PairPanel(title: "Pair your Mac") {}
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 20)
      Spacer(minLength: 12)
      if link.cloudAvailable {
        Button {
          useCloud()
        } label: {
          ZStack {
            Text("Use the cloud instead").opacity(joining ? 0 : 1)
            if joining { ProgressView().tint(Color.dim) }
          }
          .font(.geist(15, .medium))
          .foregroundStyle(Color.dim)
          .padding(.vertical, 10)
          .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
        .transition(.opacity)
      }
      if let problem {
        Text(problem).font(.geist(13)).foregroundStyle(Color.faint).transition(.opacity)
      }
    }
    .padding(.horizontal, 24)
    .padding(.bottom, 8)
    // an iPad's page is wide: the panel keeps a phone's proportions in the middle of it
    .readable(480)
    .animation(.ease, value: link.cloudAvailable)
    .animation(.ease, value: problem)
    .task { await link.probe() }
    .onAppear { withAnimation(.easeOut(duration: 1.0)) { shown = true } }
  }

  private func useCloud() {
    guard !joining else { return }
    joining = true
    Task {
      defer { joining = false }
      do { try await link.useCloud() } catch { problem = error.localizedDescription }
    }
  }
}

/** A short sideways shake, for an answer that didn't work. Bump `count` inside withAnimation. */
struct Shake: ViewModifier, Animatable {
  var count: Int
  var animatableData: CGFloat

  init(count: Int) {
    self.count = count
    self.animatableData = CGFloat(count)
  }

  func body(content: Content) -> some View {
    content
      .offset(x: sin(animatableData * .pi * 4) * 7 * (1 - (animatableData - floor(animatableData))))
  }
}
