import SwiftUI

@main
struct SparkApp: App {
  @State private var link = Link()
  @Environment(\.scenePhase) private var phase

  init() {
    let bar = UINavigationBar.appearance()
    bar.titleTextAttributes = [.font: UIFont.geist(17)]
    bar.largeTitleTextAttributes = [.font: UIFont.geist(34)]
  }

  var body: some Scene {
    WindowGroup {
      RootView()
        .environment(link)
        .font(.geist(17))
        .preferredColorScheme(.dark)
        .tint(.white)
    }
    .onChange(of: phase) { _, phase in
      link.setActive(phase == .active)
    }
  }
}
