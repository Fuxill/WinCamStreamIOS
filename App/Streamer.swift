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
                Text("iOS → Windows USB Stream").font(.headline)
                Text(streamer.status)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("Port: 5000 • H.264 Annex-B • Low-latency").font(.footnote)
            }
            .padding()
            .onAppear { streamer.start() }
        }
    }
}

final class Streamer: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    @Published var status: String = "Init…"

    // Capture
    private let session = AVCaptureSession()
    private var device: AVCaptureDevice?
    private let videoOutput = AVCaptureVideoDataOutput()

    // Encoder
    private var vtSession: VTCompressionSession?

    // Networking (TCP server on iPhone)
    private var listener: NWListener?
    private var connection: NWConnection?

    // Tunables
    private let targetWidth  = 1920
    private let targetHeight = 1080
    private let targetFPS: Double = 120
    private let intraOnly = true                 // GOP = 1
    private let bitrate   = 60_000_000           // ~60 Mb/s

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

        // 1080p@120; sinon fallback 60
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
            c.videoOrientation = .portrait // ou .landscapeRight
        }

        session.commitConfiguration()
        session.startRunning()
        status = "Capture OK (\(targetWidth)x\(targetHeight) @\(Int(targetFPS))fps tentative)"
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

    // MARK: Encoder (VideoToolbox)
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

        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_RealTime,             value: kCFBooleanTrue)
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_ProfileLevel,         value: kVTProfileLevel_H264_Baseline_AutoLevel)

        let gop: Int32 = intraOnly ? 1 : 30
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,  value: NSNumber(value: gop))
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_ExpectedFrameRate,    value: NSNumber(value: Int32(targetFPS)))
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_AverageBitRate,       value: NSNumber(value: bitrate))

        let limits: [NSNumber] = [NSNumber(value: bitrate/8), 1]
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_DataRateLimits,       value: limits as CFArray)

        VTCompressionSessionPrepareToEncodeFrames(vt)
        statusUpdate("Encoder prêt (bitrate \(bitrate/1_000_000) Mb/s, GOP \(gop))")
    }

    private func statusUpdate(_ s: String) {
        DispatchQueue.main.async { self.status = s }
    }

    // MARK: Capture → Encode
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let vt = vtSession,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        var flags: VTEncodeInfoFlags = []
        let st = VTCompressionSessionEncodeFrame(vt,
                                                 imageBuffer: imageBuffer,
                                                 presentationTimeStamp: pts,
                                                 duration: .invalid,
                                                 frameProperties: nil,
                                                 sourceFrameRefcon: nil,
                                                 infoFlagsOut: &flags)
        if st != noErr {
            statusUpdate("Encode err \(st)")
        }
    }

    // MARK: Encoded sample handling (Annex-B over TCP)
    fileprivate func handleEncodedSampleBuffer(_ sbuf: CMSampleBuffer) {
        guard let conn = connection,
              let dataBuffer = CMSampleBufferGetDataBuffer(sbuf) else { return }

        // Keyframe ?
        var isKey = false
        if let att = CMSampleBufferGetSampleAttachmentsArray(sbuf, createIfNecessary: false) as? [[CFString: Any]] {
            isKey = (att.first?[kCMSampleAttachmentKey_NotSync] as? Bool) == false
        }

        var payload = Data()
        if isKey, let fmt = CMSampleBufferGetFormatDescription(sbuf),
           let spspps = annexBParameterSets(from: fmt) {
            payload.append(spspps) // startcode+SPS + startcode+PPS
        }
        if let nals = annexBFromSampleBuffer(dataBuffer: dataBuffer) {
            payload.append(nals)
        }
        if !payload.isEmpty {
            conn.send(content: payload, completion: .contentProcessed { _ in })
        }
    }

    // MARK: Helpers SPS/PPS (Annex-B)
    private func annexBParameterSets(from fmt: CMFormatDescription) -> Data? {
        var spsPtr: UnsafePointer<UInt8>?
        var ppsPtr: UnsafePointer<UInt8>?
        var spsLen = 0, ppsLen = 0
        var count = 0
        var nalLenField: Int32 = 0

        let s1 = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0,
                                                                    parameterSetPointerOut: &spsPtr,
                                                                    parameterSetSizeOut: &spsLen,
                                                                    parameterSetCountOut: &count,
                                                                    nalUnitHeaderLengthOut: &nalLenField)
        let s2 = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 1,
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

    // MARK: AVCC → Annex-B (replace length prefixes by 0x00000001)
    private func annexBFromSampleBuffer(dataBuffer: CMBlockBuffer) -> Data? {
        var totalLen = 0
        var dataPtr: UnsafeMutablePointer<Int8>?
        let ok = CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0,
                                             lengthAtOffsetOut: &totalLen,
                                             totalLengthOut: &totalLen,
                                             dataPointerOut: &dataPtr)
        guard ok == noErr, let base = dataPtr else { return nil }

        var out = Data(capacity: totalLen + 64)
        var offset = 0
        let startCode: [UInt8] = [0, 0, 0, 1]

        while offset + 4 <= totalLen {
            let lenBE = base.advanced(by: offset).withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee }
            let nalLen = Int(CFSwapInt32BigToHost(lenBE))
            let naluStart = offset + 4
            let naluEnd   = naluStart + nalLen
            guard naluEnd <= totalLen else { break }
            out.append(contentsOf: startCode)
            out.append(Data(bytes: base.advanced(by: naluStart), count: nalLen))
            offset = naluEnd
        }
        return out
    }
}
