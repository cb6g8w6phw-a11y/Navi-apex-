import AVFoundation
import SwiftUI

@main
struct VelaApp: App {
    init() {
        WazeWeb.install()
        // Don't take the audio session. Live Container otherwise stops the song that was already playing.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        Task { @MainActor in LiveNav.shared.endLeftovers() }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
