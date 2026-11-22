import SwiftUI
import UIKit

/** A file to get from the host, then share or save to Files. */
struct Delivery: Identifiable, Equatable {
  enum Kind { case share, save }
  let path: String
  let kind: Kind
  let id = UUID()
}

extension View {
  /** fetches the file `request` names from `host`, shows how far along it is, then shares or saves it */
  func delivers(from host: String, _ request: Binding<Delivery?>) -> some View {
    modifier(Deliver(host: host, request: request))
  }
}

private struct Deliver: ViewModifier {
  @Environment(Link.self) private var link
  let host: String
  @Binding var request: Delivery?
  @State private var progress: Double?
  @State private var sharing: SharedFile?
  @State private var saving: URL?
  @State private var problem: String?

  func body(content: Content) -> some View {
    content
      .overlay(alignment: .bottom) {
        if let progress {
          HStack(spacing: 10) {
            ProgressView(value: progress)
              .progressViewStyle(.circular)
              .tint(.white)
              .controlSize(.small)
            Text(progress < 1 ? "Getting file \u{2026} \(Int(progress * 100))%" : "Getting file \u{2026}")
              .font(.geist(14, .medium))
              .monospacedDigit()
            Button("Cancel", systemImage: "xmark") { request = nil }
              .labelStyle(.iconOnly)
              .font(.system(size: 11, weight: .bold))
              .foregroundStyle(Color.dim)
          }
          .padding(.horizontal, 16)
          .frame(height: 44)
          .glassEffect(.regular, in: .capsule)
          .padding(.bottom, 24)
          .transition(.opacity.combined(with: .offset(y: 12)))
        }
      }
      .animation(.smooth(duration: 0.25), value: progress == nil)
      .task(id: request?.id) { await fetch() }
      .sheet(item: $sharing) { ActivityView(url: $0.url).ignoresSafeArea().presentationDetents([.medium, .large]) }
      .fileMover(isPresented: Binding(get: { saving != nil }, set: { if !$0 { saving = nil } }), file: saving) { _ in }
      .alert("Couldn't get that file", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(problem ?? "")
      }
  }

  private func fetch() async {
    guard let r = request else {
      progress = nil
      return
    }
    progress = 0
    do {
      let url = try await link.download(host, r.path) { progress = $0 }
      guard request?.id == r.id else { return }
      switch r.kind {
      case .share: sharing = SharedFile(url: url)
      case .save: saving = url
      }
    } catch is CancellationError {
    } catch {
      if request?.id == r.id { problem = error.localizedDescription }
    }
    progress = nil
    if request?.id == r.id { request = nil }
  }
}

private struct SharedFile: Identifiable {
  let url: URL
  var id: URL { url }
}

/** the system share sheet for one file */
private struct ActivityView: UIViewControllerRepresentable {
  let url: URL

  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: [url], applicationActivities: nil)
  }

  func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
