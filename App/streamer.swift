import Foundation
import AVFoundation
import VideoToolbox
import Network
import CoreMedia
import SwiftUI

@main
struct CamStreamerApp: App {
    @StateObject private var streamer = Streamer()
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 12) {
                Text("iOS → Windows USB Stream")
                    .font(.headline)
                Text(streamer.status)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("Port: 5000 • H.264 Annex B • Low-latency")
                    .font(.footnote)
            }
            .padding()
            .onAppear { streamer.start() }
        }
    }
}

final class Streamer: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var status = "Init…"
    private let session = AVCaptureSession()
    private var device: AVCaptureDevice?
    private var videoOutput = AVCaptureVideoDataOutput()
    private var vtSession: VTCompressionSession?
    private var listener: NWListener?
    private var connection: NWConnection?

    // encoder params
    private let targetWidth = 1920
    private let targetHeight = 1080
    private let targetFPS: Double = 120 // tentera 120, fallback 60 si indisponible
    private let intraOnly = true        // true = GOP 1 (latence minimale, débit plus élevé)
    private let bitrate = 60_000_000    // 60 Mb/s (ajustez si besoin)

    func start() {
        Task { @MainActor in
            self.status = "Démarrage…"
            self.setupTCP()
            self.setupCapture()
            self.setupEncoder(width: targetWidth, height: targetHeight)
        }
    }

    // MARK: USB over TCP (server on device)
    private func setupTCP() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: 5000)
            listener.newConnectionHandler = { [weak self] conn in
                self?.connection?.cancel()
                self?.connection = conn
                conn.stateUpdateHandler = { state in
                    DispatchQueue.main.async {
                        self?.status = "TCP client: \(state)"
                    }
                }
                conn.start(queue: .global())
            }
            listener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async { self?.status = "Listener: \(state)" }
            }
            listener.start(queue: .global())
            self.listener = listener
        } catch {
            self.status = "TCP error: \(error.localizedDescription)"
        }
    }

    // MARK: Camera
    private func setupCapture() {
        session.beginConfiguration()
        session.sessionPreset = .inputPriority

        guard let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            self.status = "Caméra introuvable"
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

        // Choix du format 1080p avec fps le plus élevé (vise 120)
        if !selectFormat(device: cam, width: targetWidth, height: targetHeight, fps: targetFPS) {
            _ = selectFormat(device: cam, width: targetWidth, height: targetHeight, fps: 60.0)
        }

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:
                                        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        videoOutput.setSampleBufferDelegate(self, queue: .global(qos: .userInitiated))

        guard session.canAddOutput(videoOutput) else { status = "Output refusé"; return }
        session.addOutput(videoOutput)

        if let conn = videoOutput.connection(with: .video) {
            conn.videoOrientation = .portrait // ou .landscapeRight selon votre usage
        }

        session.commitConfiguration()
        session.startRunning()
        status = "Capture OK (tentative \(targetWidth)x\(targetHeight) @\(Int(targetFPS))fps)"
    }

    private func selectFormat(device: AVCaptureDevice, width: Int, height: Int, fps: Double) -> Bool {
        var best: AVCaptureDevice.Format?
        for f in device.formats {
            let desc = f.formatDescription
            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            guard dims.width == width && dims.height == height else { continue }
            // Cherche le plus gros framerate dispo
            for r in f.videoSupportedFrameRateRanges {
                if r.maxFrameRate >= fps {
                    best = f; break
                }
            }
        }
        guard let chosen = best else { return false }
        do {
            try device.lockForConfiguration()
            device.activeFormat = chosen
            let ts = CMTime(value: 1, timescale: CMTimeScale(fps))
            device.activeVideoMinFrameDuration = ts
            device.activeVideoMaxFrameDuration = ts
            device.unlockForConfiguration()
            DispatchQueue.main.async {
                self.status = "Format fixé: \(width)x\(height) @\(Int(fps))"
            }
            return true
        } catch {
            DispatchQueue.main.async { self.status = "Format err: \(error.localizedDescription)" }
            return false
        }
    }

    // MARK: Encoder
    private func setupEncoder(width: Int, height: Int) {
        let status = VTCompressionSessionCreate(allocator: nil,
                                                width: Int32(width),
                                                height: Int32(height),
                                                codecType: kCMVideoCodecType_H264,
                                                encoderSpecification: nil,
                                                imageBufferAttributes: nil,
                                                compressedDataAllocator: nil,
                                                outputCallback: nil,
                                                refcon: nil,
                                                compressionSessionOut: &vtSession)
        guard status == noErr, let vt = vtSession else {
            self.status = "VTCompressionSessionCreate failed \(status)"; return
        }
        VTSessionSetProperty(vt, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        VTSessionSetProperty(vt, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        // Baseline profile (latence minimale)
        VTSessionSetProperty(vt, kVTCompressionPropertyKey_ProfileLevel,
                             kVTProfileLevel_H264_Baseline_AutoLevel)

        // GOP (intra-only si souhaité)
        let gop: Int32 = intraOnly ? 1 : 30
        VTSessionSetProperty(vt, kVTCompressionPropertyKey_MaxKeyFrameInterval, gop as CFTypeRef)
        VTSessionSetProperty(vt, kVTCompressionPropertyKey_ExpectedFrameRate, Int32(targetFPS) as CFTypeRef)

        // Débit
        VTSessionSetProperty(vt, kVTCompressionPropertyKey_AverageBitRate, bitrate as CFTypeRef)
        let dataRateLimits: [Int] = [bitrate/8, 1]  // bytes/sec, second
        VTSessionSetProperty(vt, kVTCompressionPropertyKey_DataRateLimits, dataRateLimits as CFArray)

        VTCompressionSessionPrepareToEncodeFrames(vt)
        statusUpdate("Encoder prêt (bitrate \(bitrate/1_000_000) Mb/s, GOP \(gop))")
    }

    private func statusUpdate(_ s: String) { DispatchQueue.main.async { self.status = s } }

    // MARK: Capture → Encode → Send
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection)
    {
        guard let vt = vtSession,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        var flagsOut: VTEncodeInfoFlags = []
        let status = VTCompressionSessionEncodeFrame(vt, imageBuffer: imageBuffer,
                                                     presentationTimeStamp: pts,
                                                     duration: .invalid,
                                                     frameProperties: nil,
                                                     sourceFrameRefcon: nil,
                                                     infoFlagsOut: &flagsOut,
                                                     outputHandler: { [weak self] status, _, sbuf, _, _, _ in
            guard status == noErr, let sbuf = sbuf else { return }
            self?.handleEncodedSampleBuffer(sbuf)
        })
        if status != noErr {
            statusUpdate("Encode err \(status)")
        }
    }

    private func handleEncodedSampleBuffer(_ sbuf: CMSampleBuffer) {
        guard let conn = connection else { return } // attend un client
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sbuf) else { return }

        // Récup SPS/PPS si frame clé
        let isKey = (CMSampleBufferGetSampleAttachmentsArray(sbuf, createIfNecessary: false) as? [[CFString: Any]])?
            .first?[kCMSampleAttachmentKey_NotSync] as? Bool == false

        var out = Data()
        if isKey, let fmt = CMSampleBufferGetFormatDescription(sbuf) {
            if let spspps = annexBParameterSets(from: fmt) {
                out.append(spspps) // startcode + SPS, startcode + PPS
            }
        }
        // Convertit AVCC → Annex B (remplace la longueur NAL par 0x00000001)
        if let nals = annexBFromSampleBuffer(dataBuffer: dataBuffer) {
            out.append(nals)
        }
        if !out.isEmpty {
            conn.send(content: out, completion: .contentProcessed({ _ in }))
        }
    }

    // MARK: Annex B helpers
    private func annexBParameterSets(from fmt: CMFormatDescription) -> Data? {
        var spsPtr: UnsafePointer<UInt8>?
        var ppsPtr: UnsafePointer<UInt8>?
        var spsLen = 0, ppsLen = 0
        var count: Int = 0
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
        let sc: [UInt8] = [0,0,0,1]
        var d = Data(sc); d.append(sps, count: spsLen)
        d.append(contentsOf: sc); d.append(pps, count: ppsLen)
        return d
    }

    private func annexBFromSampleBuffer(dataBuffer: CMBlockBuffer) -> Data? {
        var totalLen: Int = 0
        var dataPtr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: &totalLen,
                                          totalLengthOut: &totalLen, dataPointerOut: &dataPtr) == noErr,
              let base = dataPtr else { return nil }
        var out = Data(capacity: totalLen + 64)
        var offset = 0
        // NALU format AVCC: [len][NAL][len][NAL]...
        while offset + 4 <= totalLen {
            let len = base.advanced(by: offset).withMemoryRebound(to: UInt32.self, capacity: 1) { ptr in
                CFSwapInt32BigToHost(ptr.pointee)
            }
            let sc: [UInt8] = [0,0,0,1]
            out.append(contentsOf: sc)
            out.append(Data(bytes: base.advanced(by: offset + 4), count: Int(len)))
            offset += 4 + Int(len)
        }
        return out
    }
}
