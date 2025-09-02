import SwiftUI

@main
struct WinCamStreamIOSApp: App {
    @StateObject private var streamer = Streamer()
    @State private var pending = PendingConfig()

    var body: some Scene {
        WindowGroup {
            ScrollView {
                StreamerView(streamer: streamer, pending: $pending)
                    .padding(.horizontal)
                    .padding(.top, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(UIColor.systemBackground))
            .onAppear { pending = PendingConfig(from: streamer) }
        }
    }
}
