import SwiftUI
import AVFoundation
import VideoToolbox
import Network
import CoreMedia

// MARK: - VTCompression output callback (C-style)
private func vtOutputCallback(_ outputCallbackRefCon: UnsafeMutableRawPointer?,
                              _ sourceFrameRefCon: UnsafeMutableRawPointer?,
                              _ status: OSStatus,
                              _ infoFlags: VTEncodeInfoFlags,
                              _ sampleBuffer: CMSampleBuffer?) {
    guard status == noErr, let sbuf = sampleBuffer, let refCon = outputCallbackRefCon else { return }
    let streamer = Unmanaged<Streamer>.fromOpaque(refCon).takeUnretainedValue()
    streamer.handleEncodedSampleBuffer(sbuf)
}

@main
struct WinCamStreamIOSApp: App {
    @StateObject private var streamer = Streamer()
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 10) {
                Text("iOS → Windows USB Stream")
                    .font(.headline)
                Text(streamer.status)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("Port: 5000 • H.264 Annex-B • Low-latency")
                    .font(.footnote)
            }
            .padding()
            .onAppear { streamer.start() }
        }
    }
}

final class Streamer: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    // MARK: Public status
    @Published var status: String = "Init…"

    // MARK: Capture
    private let session = AVCaptureSession()
    private var device: AVCaptureDevice?
    private let videoOutput = AVCaptureVideoDataOutput()

    // MARK: Encoder
    private var vtSession: VTCompressionSession?

    // MARK: Networking (TCP server on iPhone)
    private var listener: NWListener?
    private var connection: NWConnection?

    // MARK: Tunables
    private let targetWidth  = 1920
    private let targetHeight = 1080
    private let targetFPS: Double = 120          // tentera 120, fallback 60 si indispo
    private let intraOnly = true                 // GOP = 1 (latence mini, débit ↑)
    private let bitrate   = 60_000_000           // ≈60 Mb/s – ajustez au besoin

    // MARK: Startup
    func start() {
        status = "Démarrage…"
        setupTCP()
        setupCapture()
        setupEncoder(width: targetWidth, height: targetHeight)
    }

    // MARK: TCP over usbmuxd
    private func setupTCP() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let lst = try NWListener(using: params, on: 5000)
            lst.stateUpdateHandler = { [weak self] st in
                DispatchQueue.main.async { self?.status = "Listener: \(st)" }
            }
            lst.newConnectionHandler = { [weak self] conn in
                self?.connection?.cancel()
                self?.connection = conn
                conn.stateUpdateHandler = { st in
                    DispatchQueue.main.async { self?.status = "TCP client: \(st)" }
                }
                conn.start(queue: .global(qos: .userInitiated))
            }
            lst.start(queue: .global(qos: .userInitiated))
            self.listener = lst
        } catch {
            status = "TCP error: \(error.localizedDescription)"
        }
    }

    // MARK: Camera
    private func setupCapture() {
        session.beginConfiguration()
        session.sessionPreset = .inputPriority

        guard let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            status = "Caméra introuvable"
            return
        }
        device = cam

        do {
            let input = try AVCaptureDeviceInput(device: cam)
            guard session.canAddInput(input) else { status = "Input refusé"; return }
            session.addInput(input)
        } catch {
            status = "Erreur input: \(error.localizedDescription)"
            return
        }

        // Vise 1080p@120; sinon 1080p@60
        if !selectFormat(device: cam, width: targetWidth, height: targetHeight, fps: targetFPS) {
            _ = selectFormat(device: cam, width: targetWidth, height: targetHeight, fps: 60.0)
        }

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFull_
