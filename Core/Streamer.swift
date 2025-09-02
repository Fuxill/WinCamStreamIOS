import SwiftUI
var frameProps: CFDictionary?
if forceIDRNext {
let dict: [String: Any] = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true]
frameProps = dict as CFDictionary
forceIDRNext = false
}


let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
var flags: VTEncodeInfoFlags = []
let st = VTCompressionSessionEncodeFrame(vt, imageBuffer: imageBuffer, presentationTimeStamp: pts,
duration: .invalid, frameProperties: frameProps,
sourceFrameRefcon: nil, infoFlagsOut: &flags)
if st != noErr { statusUpdate("Encode err \(st)") }
}


// MARK: Sortie encodée (Annex-B/AVCC sur TCP)
fileprivate func handleEncodedSampleBuffer(_ sbuf: CMSampleBuffer) {
guard let conn = connection, let dataBuffer = CMSampleBufferGetDataBuffer(sbuf) else { return }


// Si une frame est encore en vol → drop pour éviter backlog/latence
if sendingFrame { return }
sendingFrame = true
let currentGen = sessionGen


// Détection keyframe robuste
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
orientationObserver = NotificationCenter.default.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
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
case .landscapeLeft: newOri = .landscapeRight
case .landscapeRight: newOri = .landscapeLeft
case .portraitUpsideDown: newOri = .portrait
default: newOri = .portrait
}
if conn.videoOrientation != newOri { conn.videoOrientation = newOri }
}
}
