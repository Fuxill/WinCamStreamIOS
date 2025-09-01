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
    @State private var pending = PendingConfig()   // brouillon des réglages

    var body: some Scene {
        WindowGroup {
            NavigationView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {

                        // STATUS + CONTROLS
                        HStack {
                            Circle()
                                .fill(streamer.isRunning ? Color.green : Color.gray)
                                .frame(width: 10, height: 10)
                            Text(streamer.status)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }

                        HStack(spacing: 12) {
                            Button(streamer.isRunning ? "Stop" : "Start") {
                                if streamer.isRunning { streamer.stop() } else {
                                    streamer.start()
                                }
                            }
                            .buttonStyle(.borderedProminent)

                            Button("Apply changes") {
                                // pousse les réglages pendants dans le streamer puis restart
                                streamer.setConfig(from: pending)
                                if streamer.isRunning {
                                    streamer.restart()
                                }
                            }
                            .buttonStyle(.bordered)

                            Button("Force keyframe") {
                                streamer.forceIDRNext = true
                            }
                            .buttonStyle(.bordered)
                        }

                        Divider()

                        // PORT / PROTOCOL
                        Group {
                            Text("Network").font(.headline)

                            HStack {
                                Text("Port")
                                Spacer()
                                Stepper(value: $pending.port, in: 1024...65535, step: 1) {
                                    Text("\(pending.port)")
                                        .frame(minWidth: 60, alignment: .trailing)
                                }
                            }

                            Picker("Protocol", selection: $pending.outputProtocol) {
                                Text("H.264 Annex-B (recommandé)").tag(OutputProtocol.annexb)
                                Text("H.264 AVCC (expérimental)").tag(OutputProtocol.avcc)
                            }
                            .pickerStyle(.inline)
                        }

                        Divider()

                        // VIDEO SETTINGS
                        Group {
                            Text("Video").font(.headline)

                            Picker("Resolution", selection: $pending.resolution) {
                                ForEach(Resolution.allCases, id: \.self) { r in
                                    Text(r.label).tag(r)
                                }
                            }.pickerStyle(.segmented)

                            HStack {
                                Text("FPS: \(Int(pending.fps))")
                                Slider(value: $pending.fps, in: 24...240, step: 1)
                            }

                            HStack {
                                Text("Bitrate: \(Int(pending.bitrate/1_000_000)) Mb/s")
                                Slider(value: $pending.bitrate, in: 5_000_000...120_000_000, step: 1_000_000)
                            }

                            Toggle("All-I (GOP=1, latence minimale)", isOn: $pending.intraOnly)

                            Picker("Orientation", selection: $pending.orientation) {
                                Text("Portrait").tag(AVCaptureVideoOrientation.portrait)
                                Text("Paysage droite").tag(AVCaptureVideoOrientation.landscapeRight)
                                Text("Paysage gauche").tag(AVCaptureVideoOrientation.landscapeLeft)
                            }.pickerStyle(.segmented)
                        }

                        Divider()

                        // TIPS
                        Text("Astuce : après Apply, lance `iproxy \(pending.port) \(pending.port)` puis `ffplay -f h264 -fflags nobuffer -flags low_delay -probesize 2048 -analyzeduration 0 -framedrop -i tcp://127.0.0.1:\(pending.port)`.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                    .padding()
                }
                .navigationTitle("WinCamStream iOS")
                .onAppear {
                    // init du brouillon avec la config courante
                    pending = PendingConfig(from: streamer)
                }
            }
        }
    }
}

// MARK: - Résolutions proposées (simples, robustes)
enum Resolution: CaseIterable {
    case r720p, r1080p, r4k
    var width: Int {
        switch self { case .r720p: return 1280; case .r1080p: return 1920; case .r4k: return 3840 }
    }
    var height: Int {
        switch self { case .r720p: return 720; case .r1080p: return 1080; case .r4k: return 2160 }
    }
    var label: String {
        switch self { case .r720p: return "720p"; case .r1080p: return "1080p"; case .r4k: return "4K" }
    }
}

enum OutputProtocol {
    case annexb
    case avcc
}

struct PendingConfig {
    var port: UInt16 = 5000
    var resolution: Resolution = .r1080p
    var fps: Double = 120
    var bitrate: Double = 60_000_000
    var intraOnly: Bool = true
    var outputProtocol: OutputProtocol = .annexb
    var orientation: AVCaptureVideoOrientation = .portrait

    init() {}
    init(from s: Streamer) {
        port = s.listenPort
        // map width/height to Resolution enum
        let map: [Resolution] = [.r720p, .r1080p, .r4k]
        let found = map.first { $0.width == s.targetWidth && $0.height == s.targetHeight }
        resolution = found ?? .r1080p
        fps = s.targetFPS
        bitrate = Double(s.bitrate)
        intraOnly = s.intraOnly
        outputProtocol = s.outputProtocol
        orientation = s.orientation
    }
}

final class Streamer: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    @Published var status: String = "Init…"
    @Published var isRunning: Bool = false

    // Capture
    private let session = AVCaptureSession()
    private var device: AVCaptureDevice?
    private let videoOutput = AVCaptureVideoDataOutput()

    // Encoder
    private var vtSession: VTCompressionSession?

    // Réseau (serveur TCP sur l’iPhone)
    private var listener: NWListener?
    private var connection: NWConnection?

    // Réglages courants (modifiables via Apply)
    @Published var listenPort: UInt16 = 5000
    @Published var targetWidth: Int = 1920
    @Published var targetHeight: Int = 1080
    @Published var targetFPS: Double = 120
    @Published var intraOnly: Bool = true
    @Published var bitrate: Int = 60_000_000
    @Published var outputProtocol: OutputProtocol = .annexb
    @Published var orientation: AVCaptureVideoOrientation = .portrait

    // Correctifs flux / keyframe
    fileprivate var sentCodecHeader = false        // SPS/PPS déjà envoyés ?
    fileprivate var forceIDRNext    = false        // forcer IDR sur la prochaine frame encodée

    // MARK: - Public config API
    func setConfig(from p: PendingConfig) {
        listenPort = p.port
        targetWidth = p.resolution.width
        targetHeight = p.resolution.height
        targetFPS = p.fps
        bitrate = Int(p.bitrate)
        intraOnly = p.intraOnly
        outputProtocol = p.outputProtocol
        orientation = p.orientation
    }

    // MARK: - Lifecycle
    func start() {
        guard !isRunning else { return }
        status = "Démarrage…"
        setupTCP(on: listenPort)
        setupCapture()
        setupEncoder(width: targetWidth, height: targetHeight)
        isRunning = true
    }

    func stop() {
        listener?.cancel(); listener = nil
        connection?.cancel(); connection = nil
        session.stopRunning()
        if let vt = vtSession {
            VTCompressionSessionCompleteFrames(vt, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(vt)
        }
        vtSession = nil
        isRunning = false
        status = "Arrêté"
    }

    func restart() {
        stop()
        // petite latence pour libérer le HW encoder proprement
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.start()
        }
    }

    // MARK: - TCP over usbmuxd
    private func setupTCP(on port: UInt16) {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let lst = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            lst.stateUpdateHandler = { [weak self] st in
                DispatchQueue.main.async { self?.status = "Listener(\(port)): \(st)" }
            }
            lst.newConnectionHandler = { [weak self] conn in
                guard let self else { return }
                self.connection?.cancel()
                self.connection = conn

                // À chaque nouvelle connexion : ré-envoyer SPS/PPS et forcer une keyframe
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

    // MARK: - Camera
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

        // Vise target; sinon fallback 60
        if !selectFormat(device: cam, width: targetWidth, height: targetHeight, fps: targetFPS) {
            _ = selectFormat(device: cam, width: targetWidth, height: targetHeight, fps: 60.0)
        }

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        videoOutput.setSampleBufferDelegate(self, queue: .global(qos: .userInitiated))
        guard session.canAddOutput(videoOutput) else { status = "Output refusé"; return }
        session.addOutput(videoOutput)

        if let c = videoOutput.connection(with: .video) {
            c.videoOrientation = orientation
        }

        session.commitConfiguration()
        session.startRunning()
        status = "Capture OK (\(targetWidth)x\(targetHeight) @\(Int(targetFPS)) fps tentative)"
    }

    private func selectFormat(device: AVCaptureDevice, width: Int, height: Int, fps: Double) -> Bool {
        var chosen: AVCaptureDevice.Format?
        for f in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            guard dims.width == width && dims.height == height else { continue }
            if f.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= fps }) {
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

    // MARK: - Encoder (VideoToolbox)
    private func setupEncoder(width: Int, height: Int) {
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let rc = VTCompressionSessionCreate(allocator: nil,
                                            width: Int32(width),
                                            height: Int32(height),
                                            codecType: kCMVideoCodecType_H264,
                                            encoderSpecification: nil,
                                            imageBufferAttributes: nil,
                                            compressedDataAllocator: nil,
                                            outputCallback: vtOutputCallback,
                                            refcon: refcon,
                                            compressionSessionOut: &vtSession)
        guard rc == noErr, let vt = vtSession else {
            status = "VTCompressionSessionCreate failed \(rc)"
            return
        }

        // Propriétés
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_RealTime,             value: kCFBooleanTrue)
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_ProfileLevel,         value: kVTProfileLevel_H264_Baseline_AutoLevel)

        let gop: Int32 = intraOnly ? 1 : 30
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,  value: NSNumber(value: gop))
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_ExpectedFrameRate,    value: NSNumber(value: Int32(targetFPS)))
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_AverageBitRate,       value: NSNumber(value: bitrate))

        let limits: [NSNumber] = [NSNumber(value: bitrate/8), NSNumber(value: 1)] // bytes/sec, seconds
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_DataRateLimits,       value: limits as CFArray)

        VTCompressionSessionPrepareToEncodeFrames(vt)
        statusUpdate("Encoder prêt (bitrate \(bitrate/1_000_000) Mb/s, GOP \(gop))")
    }

    private func statusUpdate(_ s: String) {
        DispatchQueue.main.async { self.status = s }
    }

    // MARK: - Capture → Encode
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let vt = vtSession,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Force IDR sur la prochaine frame si demandé
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

    // MARK: - Sortie encodée (Annex-B/AVCC sur TCP)
    fileprivate func handleEncodedSampleBuffer(_ sbuf: CMSampleBuffer) {
        guard let conn = connection,
              let dataBuffer = CMSampleBufferGetDataBuffer(sbuf) else { return }

        // Détection keyframe robuste (typage explicite)
        var isKey = true
        if let attachmentsCF = CMSampleBufferGetSampleAttachmentsArray(sbuf, createIfNecessary: false) {
            if let attachments = attachmentsCF as? [[CFString: Any]] {
                if let notSync = attachments.first?[kCMSampleAttachmentKey_NotSync] as? Bool {
                    isKey = !notSync
                }
            }
        }

        var payload = Data()

        if let fmt = CMSampleBufferGetFormatDescription(sbuf) {
            switch outputProtocol {
            case .annexb:
                if let spspps = annexBParameterSets(from: fmt) {
                    if isKey { payload.append(spspps); sentCodecHeader = true }
                    else if !sentCodecHeader { payload.append(spspps); sentCodecHeader = true }
                }
                if let nals = annexBFromSampleBuffer(dataBuffer: dataBuffer) {
                    payload.append(nals)
                }

            case .avcc:
                // Envoie SPS/PPS en AVCC (longueur 4o) au moins une fois et à chaque keyframe
                if let spspps = avccParameterSets(from: fmt) {
                    if isKey { payload.append(spspps); sentCodecHeader = true }
                    else if !sentCodecHeader { payload.append(spspps); sentCodecHeader = true }
                }
                if let raw = rawFromSampleBuffer(dataBuffer: dataBuffer) {
                    payload.append(raw) // NALs avec longueurs 4o
                }
            }
        }

        if !payload.isEmpty {
            conn.send(content: payload, completion: .contentProcessed { _ in })
        }
    }

    // MARK: - Helpers SPS/PPS Annex-B
    private func annexBParameterSets(from fmt: CMFormatDescription) -> Data? {
        var spsPtr: UnsafePointer<UInt8>?
        var ppsPtr: UnsafePointer<UInt8>?
        var spsLen = 0, ppsLen = 0
        var count = 0
        var nalLenField: Int32 = 0

        let s1 = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt,
                                                                    parameterSetIndex: 0,
                                                                    parameterSetPointerOut: &spsPtr,
                                                                    parameterSetSizeOut: &spsLen,
                                                                    parameterSetCountOut: &count,
                                                                    nalUnitHeaderLengthOut: &nalLenField)
        let s2 = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt,
                                                                    parameterSetIndex: 1,
                                                                    parameterSetPointerOut: &ppsPtr,
                                                                    parameterSetSizeOut: &ppsLen,
                                                                    parameterSetCountOut: &count,
                                                                    nalUnitHeaderLengthOut: &nalLenField)
        guard s1 == noErr, s2 == noErr, let sps = spsPtr, let pps = ppsPtr else { return nil }

        let startCode: [UInt8] = [0, 0, 0, 1]
        var d = Data()
        d.append(contentsOf: startCode); d.append(sps, count: spsLen)
        d.append(contentsOf: startCode); d.append(pps, count: ppsLen)
        return d
    }

    // MARK: - Helpers SPS/PPS AVCC (longueurs 4o)
    private func avccParameterSets(from fmt: CMFormatDescription) -> Data? {
        var spsPtr: UnsafePointer<UInt8>?
        var ppsPtr: UnsafePointer<UInt8>?
        var spsLen = 0, ppsLen = 0
        var count = 0
        var nalLenField: Int32 = 0

        let s1 = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt,
                                                                    parameterSetIndex: 0,
                                                                    parameterSetPointerOut: &spsPtr,
                                                                    parameterSetSizeOut: &spsLen,
                                                                    parameterSetCountOut: &count,
                                                                    nalUnitHeaderLengthOut: &nalLenField)
        let s2 = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt,
                                                                    parameterSetIndex: 1,
                                                                    parameterSetPointerOut: &ppsPtr,
                                                                    parameterSetSizeOut: &ppsLen,
                                                                    parameterSetCountOut: &count,
                                                                    nalUnitHeaderLengthOut: &nalLenField)
        guard s1 == noErr, s2 == noErr, let sps = spsPtr, let pps = ppsPtr else { return nil }

        func beLen(_ n: Int) -> [UInt8] {
            let v = UInt32(n).bigEndian
            return [UInt8(truncatingIfNeeded: v >> 24),
                    UInt8(truncatingIfNeeded: v >> 16),
                    UInt8(truncatingIfNeeded: v >> 8),
                    UInt8(truncatingIfNeeded: v)]
        }

        var d = Data()
        d.append(contentsOf: beLen(spsLen)); d.append(sps, count: spsLen)
        d.append(contentsOf: beLen(ppsLen)); d.append(pps, count: ppsLen)
        return d
    }

    // MARK: - AVCC → Annex-B (remplace longueurs par 0x00000001)
    private func annexBFromSampleBuffer(dataBuffer: CMBlockBuffer) -> Data? {
        var lengthAtOffset: Int = 0
        var totalLength: Int = 0
        var dataPtr: UnsafeMutablePointer<Int8>?

        let ok = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPtr
        )
        guard ok == noErr, let base = dataPtr else { return nil }

        var out = Data(capacity: totalLength + 64)
        var offset = 0
        let startCode: [UInt8] = [0, 0, 0, 1]

        while offset + 4 <= totalLength {
            // Longueur big-endian
            let lenBE = base.advanced(by: offset).withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee }
            let nalLen = Int(CFSwapInt32BigToHost(lenBE))

            let naluStart = offset + 4
            let naluEnd   = naluStart + nalLen
            guard naluEnd <= totalLength else { break }

            out.append(contentsOf: startCode)
            out.append(Data(bytes: UnsafeRawPointer(base.advanced(by: naluStart)), count: nalLen))

            offset = naluEnd
        }
        return out
    }

    // MARK: - AVCC brut (copie telle quelle, longueurs 4o)
    private func rawFromSampleBuffer(dataBuffer: CMBlockBuffer) -> Data? {
        var totalLength: Int = 0
        var lengthAtOffset: Int = 0
        var dataPtr: UnsafeMutablePointer<Int8>?

        let ok = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPtr
        )
        guard ok == noErr, let base = dataPtr else { return nil }
        return Data(bytes: UnsafeRawPointer(base), count: totalLength)
    }
}
