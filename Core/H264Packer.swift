import Foundation
import CoreMedia

enum H264Packer {
    // SPS/PPS en Annex-B
    static func annexBParameterSets(from fmt: CMFormatDescription) -> Data? {
        var spsPtr: UnsafePointer<UInt8>?
        var ppsPtr: UnsafePointer<UInt8>?
        var spsLen = 0, ppsLen = 0
        var count = 0
        var nalLenField: Int32 = 0

        let s1 = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0,
            parameterSetPointerOut: &spsPtr, parameterSetSizeOut: &spsLen, parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: &nalLenField)
        let s2 = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 1,
            parameterSetPointerOut: &ppsPtr, parameterSetSizeOut: &ppsLen, parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: &nalLenField)
        guard s1 == noErr, s2 == noErr, let sps = spsPtr, let pps = ppsPtr else { return nil }

        let start: [UInt8] = [0,0,0,1]
        var d = Data()
        d.append(contentsOf: start); d.append(sps, count: spsLen)
        d.append(contentsOf: start); d.append(pps, count: ppsLen)
        return d
    }

    // SPS/PPS en AVCC (longueurs 4 octets)
    static func avccParameterSets(from fmt: CMFormatDescription) -> Data? {
        var spsPtr: UnsafePointer<UInt8>?
        var ppsPtr: UnsafePointer<UInt8>?
        var spsLen = 0, ppsLen = 0
        var count = 0
        var nalLenField: Int32 = 0

        let s1 = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0,
            parameterSetPointerOut: &spsPtr, parameterSetSizeOut: &spsLen, parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: &nalLenField)
        let s2 = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 1,
            parameterSetPointerOut: &ppsPtr, parameterSetSizeOut: &ppsLen, parameterSetCountOut: &count,
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

    // AVCC → Annex-B
    static func annexBFromSampleBuffer(dataBuffer: CMBlockBuffer) -> Data? {
        var lengthAtOffset: Int = 0
        var totalLength: Int = 0
        var dataPtr: UnsafeMutablePointer<Int8>?

        let ok = CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0,
                                             lengthAtOffsetOut: &lengthAtOffset,
                                             totalLengthOut: &totalLength,
                                             dataPointerOut: &dataPtr)
        guard ok == noErr, let base = dataPtr else { return nil }

        var out = Data(capacity: totalLength + 64)
        var offset = 0
        let start: [UInt8] = [0,0,0,1]
        while offset + 4 <= totalLength {
            let lenBE = base.advanced(by: offset)
                .withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee }
            let nalLen = Int(CFSwapInt32BigToHost(lenBE))
            let naluStart = offset + 4
            let naluEnd = naluStart + nalLen
            guard naluEnd <= totalLength else { break }
            out.append(contentsOf: start)
            out.append(Data(bytes: UnsafeRawPointer(base.advanced(by: naluStart)),
                            count: nalLen))
            offset = naluEnd
        }
        return out
    }

    // AVCC brut (conserve les longueurs 4o)
    static func rawFromSampleBuffer(dataBuffer: CMBlockBuffer) -> Data? {
        var totalLength: Int = 0
        var lengthAtOffset: Int = 0
        var dataPtr: UnsafeMutablePointer<Int8>?
        let ok = CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0,
                                             lengthAtOffsetOut: &lengthAtOffset,
                                             totalLengthOut: &totalLength,
                                             dataPointerOut: &dataPtr)
        guard ok == noErr, let base = dataPtr else { return nil }
        return Data(bytes: UnsafeRawPointer(base), count: totalLength)
    }
}
