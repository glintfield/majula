import SwiftUI

@main
struct SpikeHostApp: App {
  @Environment(\.scenePhase) private var scenePhase
  @State private var watch = ResumableWatch.fromEnvironment()

  var body: some Scene {
    WindowGroup {
      ContentView(watch: watch)
    }
    .onChange(of: scenePhase, initial: true) { _, phase in
      // iOS suspends a backgrounded app's sockets, so drop the stream and resume on return
      switch phase {
      case .active: watch.start()
      case .background: watch.stop()
      default: break
      }
    }
  }
}

struct ContentView: View {
  let watch: ResumableWatch

  var body: some View {
    Grid(alignment: .leading) {
      row("lastSeq", "\(watch.lastSeq)")
      row("connects", "\(watch.connects)")
      row("gaps", "\(watch.gaps)")
      row("status", watch.status)
    }
    .padding()
  }

  private func row(_ name: String, _ value: String) -> some View {
    GridRow {
      Text(name)
      Text(value).accessibilityIdentifier(name)
    }
  }
}
