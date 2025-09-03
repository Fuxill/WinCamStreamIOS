import SwiftUI
import AVFoundation
import VideoToolbox
import Network
import CoreMedia
import UIKit
import CoreMotion

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

    // MARK: - Published for UI
    @Published var status: String = "Init…"
    @Published var isRunning: Bool = false
    @Published var isBusy: Bool = false
    @Published var metrics: String = ""

    // Exposés à l’UI
    @Published var listenPort: UInt16 = 5000
    @Published var targetWidth: Int = 1920
    @Published var targetHeight: Int = 1080
    @Published var targetFPS: Double = 60
    @Published var intraOnly: Bool = false
    @Published var bitrate: Int = 35_000_000
    @Published var outputProtocol: OutputProtocol = .annexb
    @Published var orientation: AVCaptureVideoOrientation = .portrait
    @Published var autoRotate: Bool = true
    @Published var profile: H264Profile = .high
    @Published var entropy: H264Entropy = .cabac

    // NOUVEAU : (dés)activer l’adaptation auto
    @Published var adaptationEnabled: Bool = true

    // NOUVEAU : frames “en vol” réglables (1 ↔ 2 généralement)
    @Published private(set) var maxInFlight: Int = 2

    // MARK: - Queues
    private let controlQ = DispatchQueue(label: "Streamer.control", qos: .userInitiated)  // état réseau, adaptation, slots
    private let sessionQ = DispatchQueue(label: "Streamer.session", qos: .userInteractive) // capture + encode

    // MARK: - Capture
    private let session = AVCaptureSession()
    private var device: AVCaptureDevice?
    private let videoOutput = AVCaptureVideoDataOutput()

    // MARK: - Encoder
    private var vtSession: VTCompressionSession?

    // MARK: - Réseau
    private var listener: NWListener?
    private var connection: NWConnection?

    // MARK: - Sync & sécurité
    fileprivate var sentCodecHeader = false
    fileprivate var forceIDRNext = false
    private var sessionGen: UInt64 = 0

    // File d’envoi
    private var inFlight: Int = 0

    // Stats
    private var statsTimer: DispatchSourceTimer?
    private var bytesWindow: Int = 0
    private var framesWindow: Int = 0

    // Adaptation
    private var dropCountWindow: Int = 0
    private var adaptTimer: DispatchSourceTimer?

    // Cache des headers pour “hot-restart”
    private var lastSpsPpsAnnexB: Data?
    private var lastAvccConfig: Data?

    // Auto-rotate (CoreMotion + fallback notifications)
    private let motion = CMMotionManager()
    private var lastMotionOrientation: AVCaptureVideoOrientation?
    private var orientationObserver: NSObjectProtocol?
    private var didBeginOrientationNotifications = false

    // MARK: - State machine
    private enum State { case idle, starting, running, stopping }
    private var state: State = .idle

    // MARK: - Helpers d’API pour l’UI
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

    func applyOrRestart(with new: PendingConfig) {
        controlQ.async {
            let needsRestart =
                new.resolution.width  != self.targetWidth  ||
                new.resolution.height != self.targetHeight ||
                new.profile           != self.profile      ||
                new.entropy           != self.entropy      ||
                new.outputProtocol    != self.outputProtocol ||
                new.port              != self.listenPort

            self.setConfig(from: new)

            guard self.isRunning else { return }
            if needsRestart { self.restart() }
            else { self.applyLiveTweaks() }
        }
    }

    // NOUVEAU : Activer/Désactiver adaptation auto
    func setAdaptation(enabled: Bool) {
        controlQ.async {
            self.adaptationEnabled = enabled
            if enabled { self.startAdaptation() } else { self.stopAdaptation() }
        }
    }

    // NOUVEAU : Régler frames en vol (1..4, recommandation 1 ou 2)
    func setMaxInFlight(_ v: Int) {
        controlQ.async {
            let nv = max(1, min(4, v))
            self.maxInFlight = nv
            if self.inFlight > nv { self.inFlight = nv }
        }
    }

    func requestKeyframe() { controlQ.async { [weak self] in self?.forceIDRNext = true } }

    func start() {
        guard state == .idle else { return }
        DispatchQueue.main.async { self.isBusy = true; self.status = "Checking camera…" }

        ensureCameraAuthorized { [weak self] granted in
            guard let self = self else { return }
            guard granted else {
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.status = "Accès caméra refusé (Réglages > Confidentialité > Caméra)"
                }
                return
            }

            self.controlQ.async {
                guard self.state == .idle else { return }
                self.state = .starting

                self.sessionGen &+= 1
                self.sentCodecHeader = false
                self.forceIDRNext = true
                self.inFlight = 0
                self.dropCountWindow = 0

                DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = true }

                self.setupTCP(on: self.listenPort)

                self.sessionQ.async {
                    self.setupCapture()
                    self.setupEncoder(width: self.targetWidth, height: self.targetHeight)
                    self.startStats()
                    if self.adaptationEnabled { self.startAdaptation() } else { self.stopAdaptation() }
                    DispatchQueue.main.async {
                        self.installOrientationObserverIfNeeded()
                        self.state = .running
                        self.isRunning = true
                        self.isBusy = false
                        self.status = "Running"
                    }
                }
            }
        }
    }

    func stop() {
        controlQ.async {
            guard self.state == .running else { return }
            self.state = .stopping
            DispatchQueue.main.async { self.isBusy = true }

            self.sessionQ.sync {
                self.videoOutput.setSampleBufferDelegate(nil, queue: nil)
                self.session.stopRunning()
                if let vt = self.vtSession {
                    self.vtSession = nil
                    VTCompressionSessionCompleteFrames(vt, untilPresentationTimeStamp: .invalid)
                    VTCompressionSessionInvalidate(vt)
                }
            }

            self.connection?.cancel(); self.connection = nil
            self.listener?.cancel(); self.listener = nil

            DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = false }

            self.stopStats()
            self.stopAdaptation()
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
                self.controlQ.asyncAfter(deadline: .now() + 0.5) { self.start() }
            case .idle:
                self.start()
            default:
                break
            }
        }
    }

    // MARK: - Live tweaks (sans restart)
    private func applyLiveTweaks() {
        sessionQ.async {
            if let vt = self.vtSession {
                VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_AverageBitRate,
                                     value: NSNumber(value: self.bitrate))
                let limits: [NSNumber] = [NSNumber(value: self.bitrate/8), NSNumber(value: 1)]
                VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_DataRateLimits,
                                     value: limits as CFArray)
                VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                                     value: NSNumber(value: Int32(self.targetFPS)))
                let gop: Int32 = self.intraOnly ? 1 : 60
                VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                                     value: NSNumber(value: gop))
            }
            if let dev = self.device {
                do {
                    try dev.lockForConfiguration()
                    let ts = CMTime(value: 1, timescale: CMTimeScale(self.targetFPS))
                    dev.activeVideoMinFrameDuration = ts
                    dev.activeVideoMaxFrameDuration = ts
                    dev.unlockForConfiguration()
                } catch { /* ignore */ }
            }
            if let conn = self.videoOutput.connection(with: .video) {
                conn.videoOrientation = self.orientation
            }
            // S’assure que le décodage repart clean après modifs
            self.sentCodecHeader = false
            self.forceIDRNext = true

            DispatchQueue.main.async { self.status = "Live updated (bitrate/fps/GOP/orientation)" }
        }
    }

    // MARK: - Permissions
    private func ensureCameraAuthorized(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default: completion(false)
        }
    }

    // MARK: - TCP over usbmuxd
    private func setupTCP(on port: UInt16) {
        do {
            guard let p = NWEndpoint.Port(rawValue: port) else {
                DispatchQueue.main.async { self.status = "Port invalide \(port)" }
                return
            }

            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            let params = NWParameters(tls: nil, tcp: tcp)
            params.allowLocalEndpointReuse = true
            params.serviceClass = .interactiveVideo

            let lst = try NWListener(using: params, on: p)
            lst.stateUpdateHandler = { [weak self] st in
                DispatchQueue.main.async { self?.status = "Listener(\(port)): \(st)" }
            }
            lst.newConnectionHandler = { [weak self] conn in
                guard let self = self else { return }
                // Remplace l’ancienne connexion
                self.connection?.cancel()
                self.connection = conn
                self.sentCodecHeader = false
                self.forceIDRNext = true
                self.controlQ.async { self.inFlight = 0 }

                conn.stateUpdateHandler = { [weak self] st in
                    guard let self = self else { return }
                    DispatchQueue.main.async { self.status = "TCP client: \(st)" }

                    // HOT-RESTART : à l’état ready, on pousse immédiatement SPS/PPS
                    if case .ready = st {
                        self.controlQ.async {
                            switch self.outputProtocol {
                            case .annexb:
                                if let hdr = self.lastSpsPpsAnnexB {
                                    conn.send(content: hdr, completion: .contentProcessed { _ in })
                                    self.sentCodecHeader = true
                                }
                            case .avcc:
                                if let hdr = self.lastAvccConfig {
                                    conn.send(content: hdr, completion: .contentProcessed { _ in })
                                    self.sentCodecHeader = true
                                }
                            }
                            self.forceIDRNext = true
                        }
                    }
                }
                conn.start(queue: .global(qos: .userInitiated))
            }
            lst.start(queue: .global(qos: .userInitiated))
            self.listener = lst
        } catch {
            DispatchQueue.main.async { self.status = "TCP error: \(error.localizedDescription)" }
        }
    }

    // MARK: - Camera
    private func setupCapture() {
        session.beginConfiguration()
        session.sessionPreset = .inputPriority

        guard let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            DispatchQueue.main.async { self.status = "Caméra introuvable" }
            session.commitConfiguration()
            return
        }
        device = cam

        do {
            let input = try AVCaptureDeviceInput(device: cam)
            guard session.canAddInput(input) else {
                DispatchQueue.main.async { self.status = "Input refusé" }
                session.commitConfiguration()
                return
            }
            session.addInput(input)
        } catch {
            DispatchQueue.main.async { self.status = "Erreur input: \(error.localizedDescription)" }
            session.commitConfiguration()
            return
        }

        let maxF = maxSupportedFPS(width: targetWidth, height: targetHeight)
        if targetFPS > maxF { targetFPS = maxF }
        if !selectFormat(device: cam, width: targetWidth, height: targetHeight, fps: targetFPS) {
            _ = selectFormat(device: cam, width: targetWidth, height: targetHeight, fps: min(60.0, maxF))
        }

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        videoOutput.setSampleBufferDelegate(self, queue: sessionQ)
        guard session.canAddOutput(videoOutput) else {
            DispatchQueue.main.async { self.status = "Output refusé" }
            session.commitConfiguration()
            return
        }
        session.addOutput(videoOutput)

        if let c = videoOutput.connection(with: .video) {
            c.videoOrientation = orientation
            if c.isVideoStabilizationSupported { c.preferredVideoStabilizationMode = .off }
        }

        session.commitConfiguration()
        session.startRunning()
        DispatchQueue.main.async {
            self.status = "Capture OK (\(self.targetWidth)x\(self.targetHeight) @\(Int(self.targetFPS)) fps tentative)"
        }
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
            let ts = CMTime(value: 1, timescale: CMTimeScale(fps))
            device.activeFormat = fmt
            device.activeVideoMinFrameDuration = ts
            device.activeVideoMaxFrameDuration = ts
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.status = "Format fixé: \(width)x\(Int(height)) @\(Int(fps))" }
            return true
        } catch {
            DispatchQueue.main.async { self.status = "Format err: \(error.localizedDescription)" }
            return false
        }
    }

    /// FPS max pour une résolution donnée
    func maxSupportedFPS(width: Int, height: Int) -> Double {
        let dev = device ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        guard let d = dev else { return 60 }
        var maxF: Double = 30
        for f in d.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            guard dims.width == width && dims.height == height else { continue }
            for r in f.videoSupportedFrameRateRanges { maxF = max(maxF, r.maxFrameRate) }
        }
        return maxF
    }

    // MARK: - Encoder (VideoToolbox)
    private func setupEncoder(width: Int, height: Int) {
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let rc = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                            codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                                            imageBufferAttributes: nil, compressedDataAllocator: nil,
                                            outputCallback: vtOutputCallback, refcon: refcon, compressionSessionOut: &vtSession)
        guard rc == noErr, let vt = vtSession else {
            DispatchQueue.main.async { self.status = "VTCompressionSessionCreate failed \(rc)" }
            return
        }

        // Profil
        let profileCF: CFString = {
            switch profile {
            case .baseline: return kVTProfileLevel_H264_Baseline_AutoLevel
            case .main:     return kVTProfileLevel_H264_Main_AutoLevel
            case .high:     return kVTProfileLevel_H264_High_AutoLevel
            }
        }()
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_ProfileLevel, value: profileCF)

        // Entropy (Baseline => CAVLC forcé)
        let useCabac = (profile != .baseline) && (entropy == .cabac)
        let entropyCF: CFString = useCabac ? kVTH264EntropyMode_CABAC : kVTH264EntropyMode_CAVLC
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_H264EntropyMode, value: entropyCF)

        // Temps réel + pas de B
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_RealTime,             value: kCFBooleanTrue)
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_AllowTemporalCompression,
                             value: intraOnly ? kCFBooleanFalse : kCFBooleanTrue)

        let gop: Int32 = intraOnly ? 1 : 60
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,  value: NSNumber(value: gop))
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_ExpectedFrameRate,    value: NSNumber(value: Int32(targetFPS)))
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_AverageBitRate,       value: NSNumber(value: bitrate))
        let limits: [NSNumber] = [NSNumber(value: bitrate/8), NSNumber(value: 1)]
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_DataRateLimits,       value: limits as CFArray)

        if #available(iOS 13.0, *) {
            VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_MaxFrameDelayCount,
                                 value: NSNumber(value: 1))
            VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
                                 value: kCFBooleanTrue)
        }

        VTCompressionSessionPrepareToEncodeFrames(vt)
        statusUpdate("Encoder prêt (\(profile.label) \(useCabac ? "CABAC" : "CAVLC"), \(bitrate/1_000_000) Mb/s, GOP \(gop))")
    }

    private func statusUpdate(_ s: String) { DispatchQueue.main.async { self.status = s } }

    // MARK: - Capture → Encode
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {

        // Gating “early” : on évite d’encoder si déjà plein
        let saturated = controlQ.sync { inFlight >= maxInFlight }
        if saturated { registerDrop(); return }

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

    // MARK: - Encoded output → TCP
    fileprivate func handleEncodedSampleBuffer(_ sbuf: CMSampleBuffer) {
        guard let conn = connection,
              let dataBuffer = CMSampleBufferGetDataBuffer(sbuf) else { return }

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
                    // cache pour hot-restart
                    lastSpsPpsAnnexB = spspps
                    if isKey { payload.append(spspps) }
                    else if !sentCodecHeader { payload.append(spspps); sentCodecHeader = true }
                }
                if let nals = H264Packer.annexBFromSampleBuffer(dataBuffer: dataBuffer) {
                    payload.append(nals)
                }
            case .avcc:
                if let spspps = H264Packer.avccParameterSets(from: fmt) {
                    lastAvccConfig = spspps
                    if isKey { payload.append(spspps) }
                    else if !sentCodecHeader { payload.append(spspps); sentCodecHeader = true }
                }
                if let raw = H264Packer.rawFromSampleBuffer(dataBuffer: dataBuffer) {
                    payload.append(raw)
                }
            }
        }

        guard !payload.isEmpty else { return }

        // Réservation slot in-flight (définitif) ; si saturé → drop
        let reserved = controlQ.sync { () -> Bool in
            if inFlight >= maxInFlight { return false }
            inFlight += 1
            return true
        }
        guard reserved else { registerDrop(); return }

        let currentGen = sessionGen
        bytesWindow += payload.count
        framesWindow += 1

        conn.send(content: payload, completion: .contentProcessed { [weak self] _ in
            guard let self = self else { return }
            self.controlQ.async {
                if self.sessionGen == currentGen, self.inFlight > 0 { self.inFlight -= 1 }
            }
        })
    }

    // MARK: - Stats
    private func startStats() {
        statsTimer?.cancel()
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

    // MARK: - Adaptation (débit/fps)
    private func registerDrop() { dropCountWindow += 1 }

    private func startAdaptation() {
        adaptTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: controlQ)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in self?.adaptTick() }
        t.resume()
        adaptTimer = t
    }

    private func stopAdaptation() {
        adaptTimer?.cancel(); adaptTimer = nil
        dropCountWindow = 0
    }

    private func adaptTick() {
        guard adaptationEnabled else { return }
        let drops = dropCountWindow
        dropCountWindow = 0

        if drops > 10 {
            // Trop de drops sur 2s → baisse 10% du bitrate (min 12 Mb/s)
            let newBR = max(Int(Double(bitrate) * 0.9), 12_000_000)
            if newBR != bitrate {
                bitrate = newBR
                if let vt = vtSession {
                    VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_AverageBitRate,
                                         value: NSNumber(value: bitrate))
                    let limits: [NSNumber] = [NSNumber(value: bitrate/8), NSNumber(value: 1)]
                    VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_DataRateLimits,
                                         value: limits as CFArray)
                }
                DispatchQueue.main.async {
                    self.status = "Adapt: bitrate ↓ \(self.bitrate/1_000_000) Mb/s"
                }
            } else {
                // Si déjà bas → baisse le FPS (min 30)
                let newFPS = max(30.0, floor(self.targetFPS * 0.9))
                if newFPS != self.targetFPS, let dev = self.device {
                    self.targetFPS = newFPS
                    do {
                        try dev.lockForConfiguration()
                        let ts = CMTime(value: 1, timescale: CMTimeScale(newFPS))
                        dev.activeVideoMinFrameDuration = ts
                        dev.activeVideoMaxFrameDuration = ts
                        dev.unlockForConfiguration()
                    } catch {}
                    DispatchQueue.main.async { self.status = "Adapt: fps ↓ \(Int(newFPS))" }
                }
            }
        } else if drops == 0 {
            // Aucune goutte → remonte doucement le bitrate (max 40 Mb/s)
            let newBR = min(bitrate + 2_000_000, 40_000_000)
            if newBR != bitrate, let vt = vtSession {
                bitrate = newBR
                VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_AverageBitRate,
                                     value: NSNumber(value: bitrate))
                let limits: [NSNumber] = [NSNumber(value: bitrate/8), NSNumber(value: 1)]
                VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_DataRateLimits,
                                     value: limits as CFArray)
                DispatchQueue.main.async { self.status = "Adapt: bitrate ↑ \(self.bitrate/1_000_000) Mb/s" }
            }
        }
    }

    // MARK: - Auto-rotate (CoreMotion + fallback)
    private func installOrientationObserverIfNeeded() {
        removeOrientationObserver()
        guard autoRotate else { return }

        DispatchQueue.main.async {
            if !self.didBeginOrientationNotifications {
                UIDevice.current.beginGeneratingDeviceOrientationNotifications()
                self.didBeginOrientationNotifications = true
            }
            self.orientationObserver = NotificationCenter.default.addObserver(
                forName: UIDevice.orientationDidChangeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                self?.applyDeviceOrientation() // fallback si motion indispo
            }
            self.startMotionUpdatesForOrientation()
            self.applyDeviceOrientation()
        }
    }

    private func startMotionUpdatesForOrientation() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 0.2
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self = self, let g = data?.gravity else { return }
            let ori = self.orientationFromGravity(gx: g.x, gy: g.y)
            if self.lastMotionOrientation != ori {
                self.lastMotionOrientation = ori
                self.videoOutput.connection(with: .video)?.videoOrientation = ori
            }
        }
    }

    private func orientationFromGravity(gx: Double, gy: Double) -> AVCaptureVideoOrientation {
        if abs(gx) > abs(gy) { return gx < 0 ? .landscapeRight : .landscapeLeft }
        return .portrait // évite upsideDown
    }

    private func applyDeviceOrientation() {
        guard autoRotate, let conn = videoOutput.connection(with: .video) else { return }
        if let last = lastMotionOrientation {
            if conn.videoOrientation != last { conn.videoOrientation = last }
        } else {
            let devOri = UIDevice.current.orientation
            let newOri: AVCaptureVideoOrientation
            switch devOri {
            case .landscapeLeft:      newOri = .landscapeRight
            case .landscapeRight:     newOri = .landscapeLeft
            case .portraitUpsideDown: newOri = .portrait
            case .portrait:           newOri = .portrait
            default:                  newOri = conn.videoOrientation
            }
            if conn.videoOrientation != newOri { conn.videoOrientation = newOri }
        }
    }

    private func removeOrientationObserver() {
        DispatchQueue.main.async {
            if let obs = self.orientationObserver {
                NotificationCenter.default.removeObserver(obs)
                self.orientationObserver = nil
            }
            self.motion.stopDeviceMotionUpdates()
            if self.didBeginOrientationNotifications {
                UIDevice.current.endGeneratingDeviceOrientationNotifications()
                self.didBeginOrientationNotifications = false
            }
        }
    }
}
