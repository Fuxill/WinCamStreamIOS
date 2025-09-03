import SwiftUI

@main
struct WinCamStreamIOSApp: App {
    @StateObject private var streamer = Streamer()
    @State private var pending = PendingConfig()

    var body: some Scene {
        WindowGroup {
            ZStack {
                // Fond plein écran (évite toute “bande” résiduelle)
                Color(UIColor.systemBackground).ignoresSafeArea()

                // iOS 16+ : indicateurs visibles ; iOS 15 : ScrollView simple
                Group {
                    if #available(iOS 16.0, *) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                // Fine marge top pour éviter le rognage du status
                                Color.clear.frame(height: 6)

                                StreamerView(streamer: streamer, pending: $pending)
                                    .padding(.horizontal)
                                    .padding(.top, 6)
                                    .padding(.bottom, 6)

                                // Fine marge bas pour le texte d’astuce
                                Color.clear.frame(height: 10)
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                        .scrollIndicators(.visible)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                Color.clear.frame(height: 6)

                                StreamerView(streamer: streamer, pending: $pending)
                                    .padding(.horizontal)
                                    .padding(.top, 6)
                                    .padding(.bottom, 6)

                                Color.clear.frame(height: 10)
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }
                }
            }
            .onAppear { pending = PendingConfig(from: streamer) }
        }
    }
}
