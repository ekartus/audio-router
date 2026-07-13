import SwiftUI
import MixerCore

@main
struct MixerBarApp: App {
    @StateObject private var engine = RouteEngine()

    var body: some Scene {
        MenuBarExtra("Audio Router", systemImage: "waveform") {
            MenuContentView(engine: engine)
        }
        .menuBarExtraStyle(.window)
    }
}
