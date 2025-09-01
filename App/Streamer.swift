import Foundation
import AVFoundation
import VideoToolbox
import Network
import CoreMedia
import SwiftUI

// Callback C pour VideoToolbox (VTCompressionOutputCallback)
private func vtOutputCallback(_ outputCallbackRefCon: UnsafeMutableRawPointer?,
                              _ sourceFrameRefCon: UnsafeMutableRawPointer?,
                              _ status: OSStatus,
                              _ infoFlags: VTEncodeInfoFlags,
                              _ sampleBuffer: CMSampleBuffer?) {
    guard status == noErr, let sbuf = sampleBuffer else { return }
    guard let refCon = outputCallbackRefCon else { return }
    let streamer = Unmanaged<Streamer>.fromOpaque(refCon).takeUnretainedValue()
    streamer.handleEncodedSampleBuffer(sbuf)
}

@main
struct WinCamStreamIOSApp: App {
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

    // Réglages encodeur / capture
    private let targetWidth = 1920
    private let targetHeight = 1080
    private let targetFPS: Double = 120         // tentative 120, fallback 60 si indispo
    private let intraOnly = true                // GOP=1 (latence mini, débit plus élevé)
    private let bitrate = 60_000_000            // ~60 Mb/s (ajuste si besoin)

    func start() {
        DispatchQueue.main.async {
            self.status = "Démarrage…"
        }
        setupTCP()
        setupCapture()
        setupEncoder(width: targetWidth, height: targetHeight)
    }

    // MARK: - Réseau USB (server TCP sur l’iPhone)
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

    // MARK: - Camera
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

        // 1080p @ 120 si dispo, sinon 60
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
            conn.videoOrientation = .portrait // changer si paysage souhaité
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
            for r in f.videoSupportedFrameRateRanges where r.maxFrameRate >= fps {
                best = f; break
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

    // MARK: - Encodeur VideoToolbox
    private func setupEncoder(width: Int, height: Int) {
        // refcon = pointeur non retenu vers self, récupéré dans vtOutputCallback
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let statusCreate = VTCompressionSessionCreate(allocator: nil,
                                                      width: Int32(width),
                                                      height: Int32(height),
                                                      codecType: kCMVideoCodecType_H264,
                                                      encoderSpecification: nil,
                                                      imageBufferAttributes: nil,
                                                      compressedDataAllocator: nil,
                                                      outputCallback: vtOutputCallback,
                                                      refcon: refcon,
                                                      compressionSessionOut: &vtSession)
        guard statusCreate == noErr, let vt = vtSession else {
            self.status = "VTCompressionSessionCreate failed \(statusCreate)"
            return
        }

        // Propriétés avec labels key:/value:
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_Baseline_AutoLevel)

        // GOP (=1 si intraOnly)
        let gop: Int32 = intraOnly ? 1 : 30
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: NSNumber(value: gop))
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: NSNumber(value: Int32(targetFPS)))

        // Débit + limites
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: NSNumber(value: bitrate))
        let dataRateLimits: [NSNumber] = [NSNumber(value: bitrate/8), NSNumber(value: 1)]
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_DataRateLimits,
                             value: dataRateLimits as CFArray)

        VTCompressionSessionPrepareToEncodeFrames(vt)
        statusUpdate("Encoder prêt (bitrate \(bitrate/1_000_000) Mb/s, GOP \(gop))")
    }

    private func statusUpdate(_ s: String) { DispatchQueue.main.async { self.status = s } }

    // MARK: - Capture → Encode
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let vt = vtSession,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        var flagsOut: VTEncodeInfoFlags = []
        let st = VTCompressionSessionEncodeFrame(vt,
                                                 imageBuffer: imageBuffer,
                                                 presentationTimeStamp: pts,
                                                 duration: .invalid,
                                                 frameProperties: nil,
                                                 sourceFrameRefcon: nil,
                                                 infoFlagsOut: &flagsOut)
        if st != noErr {
            statusUpdate("Encode err \(st)")
        }
    }

    // MARK: - Envoi des NALs (Annex B) sur le socket
    fileprivate func handleEncodedSampleBuffer(_ sbuf: CMSampleBuffer) {
        guard let conn = connection else { return }
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sbuf) else { return }

        // Frame clé ?
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sbuf, createIfNecessary: false) as? [[CFString: Any]]
        let isKey = (attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) == false

        var out = Data()

        if isKey, let fmt = CMSampleBufferGetFormatDescription(sbuf),
           let spspps = annexBParameterSets(from: fmt) {
            out.append(spspps) // startcode+SPS, startcode+PPS
        }

        if let nals = annexBFromSampleBuffer(dataBuffer: dataBuffer) {
            out.append(nals)
        }

        if !out.isEmpty {
            conn.send(content: out, completion: .contentProcessed { _ in })
        }
    }

    // SPS/PPS → Annex B
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
        d.append(contentsOf:
