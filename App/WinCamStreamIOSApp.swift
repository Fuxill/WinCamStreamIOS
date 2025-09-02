import SwiftUI

@main
struct WinCamStreamIOSApp: App {
    @StateObject private var streamer = Streamer()
    @State private var pending = PendingConfig()

    var body: some Scene {
        WindowGroup {
            ZStack {
                Color(UIColor.systemBackground).ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Fine marge top pour éviter tout rognage
                        Color.clear.frame(height: 6)

                        StreamerView(streamer: streamer, pending: $pending)
                            .padding(.horizontal)
                            .padding(.top, 6)
                            .padding(.bottom, 6)

                        // Fine marge bas pour laisser respirer le dernier texte
                        Color.clear.frame(height: 10)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .scrollIndicators(.visible) // iOS 17+
            }
            .onAppear { pending = PendingConfig(from: streamer) }
        }
    }
}
