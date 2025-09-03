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

    // MARK: Queues
    private let controlQ = DispatchQueue(label: "Streamer.control")
    private let sessionQ = DispatchQueue(label: "Streamer.session") // capture + encode

    // MARK: Capture
    private let session = AVCaptureSession()
    private var device: AVCaptureDevice?
    private let videoOutput = AVCaptureVideoDataOutput()

    // MARK: Encoder
    private var vtSession: VTCompressionSession?

    // MARK: Réseau
    private var listener: NWListener?
    private var connection: NWConnection?

    // MARK: Réglages (courants)
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

    // State
    private enum State { case idle, starting, running, stopping }
    private var state: State = .idle

    // Auto-rotate
    private var orientationObserver: NSObjectProtocol?
    private var didBeginOrientationNotifications = false
    private var orientationPoller: DispatchSourceTimer?

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

    /// Applique `pending` : live si possible, sinon restart propre.
    func applyOrRestart(with new: PendingConfig) {
        controlQ.async {
            // Détecte si un rebuild est requis (change le "bitstream shape")
            let needsRestart =
                new.resolution.width  != self.targetWidth  ||
                new.resolution.height != self.targetHeight ||
                new.profile           != self.profile      ||
                new.entropy           != self.entropy      ||
                new.outputProtocol    != self.outputProtocol ||
                new.port              != self.listenPort

            self.setConfig(from: new)

            guard self.isRunning else {
                // pas démarré : rien d’autre à faire
                return
            }

            if needsRestart {
                self.restart()
            } else {
                self.applyLiveTweaks()
            }
        }
    }

    /// Modifs à chaud (bitrate, fps, GOP, orientation)
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
                let gop: Int32 = self.intraOnly ? 1 : 30
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
            self.forceIDRNext = true // re-sync côté lecteur
            DispatchQueue.main.async { self.status = "Live updated (bitrate/fps/GOP/orientation)" }
        }
    }

    // MARK: Lifecycle
    func requestKeyframe() {
        controlQ.async { [weak self] in self?.forceIDRNext = true }
    }

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
                self.sendingFrame = false

                DispatchQueue.main.async {
                    UIApplication.shared.isIdleTimerDisabled = true
                }

                self.setupTCP(on: self.listenPort)

                self.sessionQ.async {
                    self.setupCapture()
                    self.setupEncoder(width: self.targetWidth, height: self.targetHeight)
                    self.startStats()
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

            DispatchQueue.main.async {
                UIApplication.shared.isIdleTimerDisabled = false
            }

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
                self.controlQ.asyncAfter(deadline: .now() + 0.3) { self.start() }
            case .idle:
                self.start()
            default:
                break
            }
        }
    }

    // MARK: Permissions
    private func ensureCameraAuthorized(_ completion: @escaping (Bool) -> Void) {
        let st = AVCaptureDevice.authorizationStatus(for: .video)
        switch st {
        case .authorized: completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default: completion(false)
        }
    }

    // MARK: TCP
    private func setupTCP(on port: UInt16) {
        do {
            guard let p = NWEndpoint.Port(rawValue: port) else {
                DispatchQueue.main.async { self.status = "Port invalide \(port)" }
                return
            }
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
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
            DispatchQueue.main.async { self.status = "TCP error: \(error.localizedDescription)" }
        }
    }

    // MARK: Camera
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

        if let c = videoOutput.connection(with: .video) { c.videoOrientation = orientation }

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

    // MARK: Encoder
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
        DispatchQueue.main.async {
            self.statusUpdate("Encoder prêt (\(self.profile.label) \(useCabac ? "CABAC" : "CAVLC"), \(self.bitrate/1_000_000) Mb/s, GOP \(gop))")
        }
    }

    private func statusUpdate(_ s: String) { DispatchQueue.main.async { self.status = s } }

    // MARK: Capture → Encode (back-pressure : on skippe si envoi en cours)
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if sendingFrame { return } // ⚠️ évite de remplir la file quand réseau plafonne

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

        if sendingFrame { return }
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
                    if isKey { payload.append(spspps) }      // toujours SPS/PPS sur IDR
                    else if !sentCodecHeader { payload.append(spspps); sentCodecHeader = true }
                }
                if let nals = H264Packer.annexBFromSampleBuffer(dataBuffer: dataBuffer) { payload.append(nals) }
            case .avcc:
                if let spspps = H264Packer.avccParameterSets(from: fmt) {
                    if isKey { payload.append(spspps) }
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

    // MARK: Auto-rotate (notif + poller, marche même avec verrou d’orientation)
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
                self?.applyDeviceOrientation()
            }
            self.startOrientationPoller() // fallback si la notif n'arrive pas
            self.applyDeviceOrientation()
        }
    }

    private func startOrientationPoller() {
        stopOrientationPoller()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in self?.applyDeviceOrientation() }
        t.resume()
        orientationPoller = t
    }

    private func stopOrientationPoller() {
        orientationPoller?.cancel(); orientationPoller = nil
    }

    private func removeOrientationObserver() {
        DispatchQueue.main.async {
            if let obs = self.orientationObserver {
                NotificationCenter.default.removeObserver(obs)
                self.orientationObserver = nil
            }
            self.stopOrientationPoller()
            if self.didBeginOrientationNotifications {
                UIDevice.current.endGeneratingDeviceOrientationNotifications()
                self.didBeginOrientationNotifications = false
            }
        }
    }

    private func applyDeviceOrientation() {
        guard autoRotate, let conn = videoOutput.connection(with: .video) else { return }
        let devOri = UIDevice.current.orientation
        let newOri: AVCaptureVideoOrientation
        switch devOri {
        case .landscapeLeft:      newOri = .landscapeRight
        case .landscapeRight:     newOri = .landscapeLeft
        case .portraitUpsideDown: newOri = .portrait
        case .portrait:           newOri = .portrait
        default:                  newOri = conn.videoOrientation // ne change rien si « unknown »
        }
        if conn.videoOrientation != newOri { conn.videoOrientation = newOri }
    }
}
