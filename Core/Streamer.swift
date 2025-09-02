import SwiftUI
import AVFoundation
import VideoToolbox
import Network
import CoreMedia
import UIKit

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

final class Streamer: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    // MARK: Published/UI
    @Published var status: String = "Init…"
    @Published var isRunning: Bool = false
    @Published var isBusy: Bool = false
    @Published var metrics: String = ""

    // MARK: Capture
    private let session = AVCaptureSession()
    private var device: AVCaptureDevice?
    private let videoOutput = AVCaptureVideoDataOutput()

    // MARK: Encoder
    private var vtSession: VTCompressionSession?

    // MARK: Réseau
    private var listener: NWListener?
    private var connection: NWConnection?

    // MARK: Réglages
    @Published var listenPort: UInt16 = 5000
    @Published var targetWidth: Int = 1920
    @Published var targetHeight: Int = 1080
    @Published var targetFPS: Double = 120
    @Published var intraOnly: Bool = true
    @Published var bitrate: Int = 60_000_000
    @Published var outputProtocol: OutputProtocol = .annexb
    @Published var orientation: AVCaptureVideoOrientation = .portrait
    @Published var autoRotate: Bool = false
    @Published var profile: H264Profile = .baseline
    @Published var entropy: H264Entropy = .cavlc

    // MARK: Anti-dérive / sécurité
    fileprivate var sentCodecHeader = false
    fileprivate var forceIDRNext = false
    private var sendingFrame = false
    private var sessionGen: UInt64 = 0

    // Stats
    private var statsTimer: DispatchSourceTimer?
    private var bytesWindow: Int = 0
    private var framesWindow: Int = 0

    // Sérialisation
    private let controlQ = DispatchQueue(label: "Streamer.control")
    private enum State { case idle, starting, running, stopping }
    private var state: State = .idle

    // MARK: Config API
    func setConfig(from p: PendingConfig) {
        listenPort   = p.port
        targetWidth  = p.resolution.width
        targetHeight = p.resolution.height
        targetFPS    = p.fps
        bitrate      = Int(p.bitrate)
        intraOnly    = p.intraOnly
        outputProtocol = p.outputProtocol
        orientation  = p.orientation
        autoRotate   = p.autoRotate
        profile      = p.profile
        entropy      = p.entropy
    }

    // MARK: Lifecycle
    func start() {
        controlQ.async {
            guard self.state == .idle else { return }
            self.state = .starting
            DispatchQueue.main.async { self.isBusy = true }

            self.sessionGen &+= 1
            self.sentCodecHeader = false
            self.forceIDRNext = true
            self.sendingFrame = false

            UIApplication.shared.isIdleTimerDisabled = true
            self.setupTCP(on: self.listenPort)
            self.setupCapture()
            self.setupEncoder(width: self.targetWidth, height: self.targetHeight)

            self.startStats()
            self.installOrientationObserverIfNeeded()

            self.state = .running
            DispatchQueue.main.async {
                self.isRunning = true
                self.isBusy = false
                self.status = "Running"
            }
        }
    }

    func stop() {
        controlQ.async {
            guard self.state == .running else { return }
            self.state = .stopping
            DispatchQueue.main.async { self.isBusy = true }

            let vt = self.vtSession
            self.vtSession = nil

            self.videoOutput.setSampleBufferDelegate(nil, queue: nil)
            self.session.stopRunning()

            if let vt = vt {
                VTCompressionSessionCompleteFrames(vt, untilPresentationTimeStamp: .invalid)
                VTCompressionSessionInvalidate(vt)
            }

            self.connection?.cancel(); self.connection = nil
            self.listener?.cancel(); self.listener = nil

            UIApplication.shared.isIdleTimerDisabled = false

            self.stopStats()
            self.removeOrientationObserver()

            self.state = .idle
            DispatchQueue.main.async {
                self.isRunning = false
                self.isBusy = false
                self.status = "Arrêté"
                self.metrics = ""
            }
        }
    }

    func restart() {
        controlQ.async {
            switch self.state {
            case .running:
                self.stop()
                self.controlQ.asyncAfter(deadline: .now() + 0.2) { self.start() }
            case .idle:
                self.start()
            default:
                break
            }
        }
    }

    // MARK: TCP
    private func setupTCP(on port: UInt16) {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let p = NWEndpoint.Port(rawValue: port)!
            let lst = try NWListener(using: params, on: p)
            lst.stateUpdateHandler = { [weak self] st in
                DispatchQueue.main.async { self?.status = "Listener(\(port)): \(st)" }
            }
            lst.newConnectionHandler = { [weak self] conn in
                guard let self = self else { return }
                self.connection?.cancel()
                self.connection = conn
                self.sentCodecHeader = false
                self.forceIDRNext = true
                conn.stateUpdateHandler = { st in
                    DispatchQueue.main.async { self.status = "TCP client: \(st)" }
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
            status = "Caméra introuvable"; return
        }
        device = cam

        do {
            let input = try AVCaptureDeviceInput(device: cam)
            guard session.canAddInput(input) else { status = "Input refusé"; return }
            session.addInput(input)
        } catch { status = "Erreur input: \(error.localizedDescription)"; return }

        let maxF = maxSupportedFPS(width: targetWidth, height: targetHeight)
        if targetFPS > maxF { targetFPS = maxF }
        if !selectFormat(device: cam, width: targetWidth, height: targetHeight, fps: targetFPS) {
            _ = selectFormat(device: cam, width: targetWidth, height: targetHeight, fps: min(60.0, maxF))
        }

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        videoOutput.setSampleBufferDelegate(self, queue: .global(qos: .userInitiated))
        guard session.canAddOutput(videoOutput) else { status = "Output refusé"; return }
        session.addOutput(videoOutput)

        if let c = videoOutput.connection(with: .video) { c.videoOrientation = orientation }

        session.commitConfiguration()
        session.startRunning()
        status = "Capture OK (\(targetWidth)x\(targetHeight) @\(Int(targetFPS)) fps tentative)"
    }

    private func selectFormat(device: AVCaptureDevice, width: Int, height: Int, fps: Double) -> Bool {
        var chosen: AVCaptureDevice.Format?
        for f in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            guard dims.width == width && dims.height == height else { continue }
            if f.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate + 0.001 >= fps }) {
                chosen = f; break
            }
        }
        guard let fmt = chosen else { return false }
        do {
            try device.lockForConfiguration()
            device.activeFormat = fmt
            let ts = CMTime(value: 1, timescale: CMTimeScale(fps))
            device.activeVideoMinFrameDuration = ts
            device.activeVideoMaxFrameDuration = ts
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.status = "Format fixé: \(width)x\(height) @\(Int(fps))" }
            return true
        } catch {
            DispatchQueue.main.async { self.status = "Format err: \(error.localizedDescription)" }
            return false
        }
    }

    /// FPS max pour une résolution donnée
    func maxSupportedFPS(width: Int, height: Int) -> Double {
        guard let dev = device ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { return 60 }
        var maxF: Double = 30
        for f in dev.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            guard dims.width == width && dims.height == height else { continue }
            for r in f.videoSupportedFrameRateRanges { maxF = max(maxF, r.maxFrameRate) }
        }
        return maxF
    }

    // MARK: Encoder
    private func setupEncoder(width: Int, height: Int) {
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let rc = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                            codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                                            imageBufferAttributes: nil, compressedDataAllocator: nil,
                                            outputCallback: vtOutputCallback, refcon: refcon, compressionSessionOut: &vtSession)
        guard rc == noErr, let vt = vtSession else { status = "VTCompressionSessionCreate failed \(rc)"; return }

        // Profil
        let profileCF: CFString = {
            switch profile {
            case .baseline: return kVTProfileLevel_H264_Baseline_AutoLevel
            case .main:     return kVTProfileLevel_H264_Main_AutoLevel
            case .high:     return kVTProfileLevel_H264_High_AutoLevel
            }
        }()
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_ProfileLevel, value: profileCF)

        // Entropy (Baseline => CAVLC)
        let useCabac = (profile != .baseline) && (entropy == .cabac)
        let entropyCF: CFString = useCabac ? kVTH264EntropyMode_CABAC : kVTH264EntropyMode_CAVLC
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_H264EntropyMode, value: entropyCF)

        // Temps réel + pas de B
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_RealTime,             value: kCFBooleanTrue)
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)

        let gop: Int32 = intraOnly ? 1 : 30
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,  value: NSNumber(value: gop))
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_ExpectedFrameRate,    value: NSNumber(value: Int32(targetFPS)))
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_AverageBitRate,       value: NSNumber(value: bitrate))
        let limits: [NSNumber] = [NSNumber(value: bitrate/8), NSNumber(value: 1)]
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_DataRateLimits,       value: limits as CFArray)

        VTCompressionSessionPrepareToEncodeFrames(vt)
        statusUpdate("Encoder prêt (\(profile.label) \(useCabac ? "CABAC" : "CAVLC"), \(bitrate/1_000_000) Mb/s, GOP \(gop))")
    }

    private func statusUpdate(_ s: String) { DispatchQueue.main.async { self.status = s } }

    // MARK: Capture → Encode
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let vt = vtSession,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        var frameProps: CFDictionary?
        if forceIDRNext {
            let dict: [String: Any] = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true]
            frameProps = dict as CFDictionary
            forceIDRNext = false
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        var flags: VTEncodeInfoFlags = []
        let st = VTCompressionSessionEncodeFrame(vt,
                                                 imageBuffer: imageBuffer,
                                                 presentationTimeStamp: pts,
                                                 duration: .invalid,
                                                 frameProperties: frameProps,
                                                 sourceFrameRefcon: nil,
                                                 infoFlagsOut: &flags)
        if st != noErr {
            statusUpdate("Encode err \(st)")
        }
    }

    // MARK: Encoded output → TCP
    fileprivate func handleEncodedSampleBuffer(_ sbuf: CMSampleBuffer) {
        guard let conn = connection,
              let dataBuffer = CMSampleBufferGetDataBuffer(sbuf) else { return }

        if sendingFrame { return } // anti-backlog
        sendingFrame = true
        let currentGen = sessionGen

        // keyframe ?
        var isKey = true
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sbuf, createIfNecessary: false) as? [Any],
           let dict = arr.first as? [String: Any],
           let notSync = dict[kCMSampleAttachmentKey_NotSync as String] as? Bool {
            isKey = !notSync
        }

        var payload = Data()
        if let fmt = CMSampleBufferGetFormatDescription(sbuf) {
            switch outputProtocol {
            case .annexb:
                if let spspps = H264Packer.annexBParameterSets(from: fmt) {
                    if isKey { payload.append(spspps); sentCodecHeader = true }
                    else if !sentCodecHeader { payload.append(spspps); sentCodecHeader = true }
                }
                if let nals = H264Packer.annexBFromSampleBuffer(dataBuffer: dataBuffer) { payload.append(nals) }
            case .avcc:
                if let spspps = H264Packer.avccParameterSets(from: fmt) {
                    if isKey { payload.append(spspps); sentCodecHeader = true }
                    else if !sentCodecHeader { payload.append(spspps); sentCodecHeader = true }
                }
                if let raw = H264Packer.rawFromSampleBuffer(dataBuffer: dataBuffer) { payload.append(raw) }
            }
        }

        if !payload.isEmpty {
            bytesWindow += payload.count
            framesWindow += 1
            conn.send(content: payload, completion: .contentProcessed { [weak self] _ in
                guard let self = self else { return }
                if self.sessionGen == currentGen { self.sendingFrame = false }
            })
        } else {
            sendingFrame = false
        }
    }

    // MARK: Stats
    private func startStats() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            let fps = self.framesWindow
            let mbps = Double(self.bytesWindow) * 8.0 / 1_000_000.0
            self.metrics = String(format: "~%2d fps • ~%.1f Mb/s", fps, mbps)
            self.framesWindow = 0
            self.bytesWindow = 0
        }
        t.resume()
        self.statsTimer = t
    }

    private func stopStats() {
        statsTimer?.cancel(); statsTimer = nil
        framesWindow = 0; bytesWindow = 0
    }

    // MARK: Auto-rotate
    private var orientationObserver: NSObjectProtocol?

    private func installOrientationObserverIfNeeded() {
        removeOrientationObserver()
        guard autoRotate else { return }
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        orientationObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.applyDeviceOrientation()
        }
        applyDeviceOrientation()
    }

    private func removeOrientationObserver() {
        if let obs = orientationObserver { NotificationCenter.default.removeObserver(obs) }
        orientationObserver = nil
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    private func applyDeviceOrientation() {
        guard let conn = videoOutput.connection(with: .video) else { return }
        let devOri = UIDevice.current.orientation
        let newOri: AVCaptureVideoOrientation
        switch devOri {
        case .landscapeLeft:      newOri = .landscapeRight
        case .landscapeRight:     newOri = .landscapeLeft
        case .portraitUpsideDown: newOri = .portrait
        default:                  newOri = .portrait
        }
        if conn.videoOrientation != newOri { conn.videoOrientation = newOri }
    }
}
