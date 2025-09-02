import SwiftUI
}


Divider()


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
.pickerStyle(.segmented)
}


Divider()


Group {
Text("Video").font(.headline)


Picker("Resolution", selection: $pending.resolution) {
ForEach(Resolution.allCases, id: \.self) { r in
Text(r.label).tag(r)
}
}
.pickerStyle(.segmented)


// Max FPS device pour la résolution choisie
Text("Max FPS supporté (device): \(maxFPSForPending())")
.font(.caption)
.foregroundStyle(.secondary)


HStack {
Text("FPS: \(Int(pending.fps))")
Slider(value: $pending.fps, in: 24...Double(max(24, maxFPSForPending())), step: 1)
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
}
.pickerStyle(.segmented)


Toggle("Auto-rotate (suivre l’orientation)", isOn: $pending.autoRotate)
}


Divider()


Group {
Text("H.264").font(.headline)
Picker("Profile", selection: $pending.profile) {
ForEach(H264Profile.allCases, id: \.self) { p in Text(p.label).tag(p) }
}
.pickerStyle(.segmented)


Picker("Entropy", selection: $pending.entropy) {
ForEach(H264Entropy.allCases, id: \.self) { e in
Text(e.label).tag(e)
}
}
.pickerStyle(.segmented)
.disabled(pending.profile == .baseline) // Baseline → CAVLC imposé
if pending.profile == .baseline {
Text("Baseline impose CAVLC (CABAC indisponible)")
.font(.caption)
.foregroundStyle(.secondary)
}
}


Divider()


Text("Astuce : après Apply, lance `iproxy \(pending.port) \(pending.port)` puis `ffplay -f h264 -fflags nobuffer -flags low_delay -probesize 2048 -analyzeduration 0 -vsync drop -use_wallclock_as_timestamps 1 -i tcp://127.0.0.1:\(pending.port)`. ")
.font(.footnote)
.foregroundStyle(.secondary)
.padding(.top, 8)
}
}
}


private extension Double { var int: Int { Int(self) } }
