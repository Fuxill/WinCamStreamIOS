import Foundation
import AVFoundation


// Résolutions préréglées (rapides) ; la limite FPS réelle est lue du device
enum Resolution: CaseIterable {
case r720p, r1080p, r4k
var width: Int { switch self { case .r720p: return 1280; case .r1080p: return 1920; case .r4k: return 3840 } }
var height: Int { switch self { case .r720p: return 720; case .r1080p: return 1080; case .r4k: return 2160 } }
var label: String { switch self { case .r720p: return "720p"; case .r1080p: return "1080p"; case .r4k: return "4K" } }
}


enum OutputProtocol { case annexb, avcc }


enum H264Profile: CaseIterable { case baseline, main, high
var label: String {
switch self { case .baseline: return "Baseline"; case .main: return "Main"; case .high: return "High" }
}
}


enum H264Entropy: CaseIterable { case cavlc, cabac
var label: String { self == .cavlc ? "CAVLC" : "CABAC" }
}


struct PendingConfig {
var port: UInt16 = 5000
var resolution: Resolution = .r1080p
var fps: Double = 120
var bitrate: Double = 60_000_000
var intraOnly: Bool = true
var outputProtocol: OutputProtocol = .annexb
var orientation: AVCaptureVideoOrientation = .portrait
var autoRotate: Bool = false
var profile: H264Profile = .baseline
var entropy: H264Entropy = .cavlc


init() {}
init(from s: Streamer) {
port = s.listenPort
let candidates: [Resolution] = [.r720p, .r1080p, .r4k]
resolution = candidates.first { $0.width == s.targetWidth && $0.height == s.targetHeight } ?? .r1080p
fps = s.targetFPS
bitrate = Double(s.bitrate)
intraOnly = s.intraOnly
outputProtocol = s.outputProtocol
orientation = s.orientation
autoRotate = s.autoRotate
profile = s.profile
entropy = s.entropy
}
}
