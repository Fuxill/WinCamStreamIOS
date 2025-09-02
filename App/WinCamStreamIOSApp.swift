import SwiftUI

@main
struct WinCamStreamIOSApp: App {
    @StateObject private var streamer = Streamer()
    @State private var pending = PendingConfig()

    var body: some Scene {
        WindowGroup {
            // Vue plein écran, sans marges haut/bas
            StreamerView(streamer: streamer, pending: $pending)
                .padding(.horizontal)
                .padding(.top, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(UIColor.systemBackground))
                .ignoresSafeArea() // <- enlève les bandes noires perçues
                .onAppear { pending = PendingConfig(from: streamer) }
        }
    }
}
