import CoreMedia
import VideoToolbox

/// Annex B (start codes) → length-prefixed CMSampleBuffer for AVSampleBufferDisplayLayer.
final class AnnexB {
    private(set) var hevc = false
    private var fmt: CMVideoFormatDescription?
    private var sets: [[UInt8]] = []

    func reset(hevc: Bool) { self.hevc = hevc; fmt = nil; sets = [] }

    private func type(_ b: UInt8) -> Int { hevc ? Int((b >> 1) & 0x3f) : Int(b & 0x1f) }

    static func nals(_ b: [UInt8], from: Int) -> [Range<Int>] {
        var out: [Range<Int>] = []
        let n = b.count
        var i = from, start = -1
        b.withUnsafeBufferPointer { p in
            while i + 2 < n {
                if p[i + 2] > 1 { i += 3; continue }                 // fast skip
                if p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 1 {
                    if start >= 0 { var e = i; while e > start && p[e - 1] == 0 { e -= 1 }; out.append(start..<e) }
                    i += 3; start = i
                } else { i += 1 }
            }
        }
        if start >= 0 && start < n { out.append(start..<n) }
        return out
    }

    func sample(_ b: [UInt8], from: Int, key: Bool, ms: UInt32) -> CMSampleBuffer? {
        var params: [[UInt8]] = []
        var body: [UInt8] = []
        body.reserveCapacity(b.count - from + 32)
        for r in AnnexB.nals(b, from: from) where !r.isEmpty {
            let t = type(b[r.lowerBound])
            let isParam = hevc ? (t >= 32 && t <= 34) : (t == 7 || t == 8)
            let isAUD = hevc ? (t == 35) : (t == 9)
            if isParam { params.append(Array(b[r])); continue }
            if isAUD { continue }
            let l = r.count
            body += [UInt8((l >> 24) & 0xff), UInt8((l >> 16) & 0xff), UInt8((l >> 8) & 0xff), UInt8(l & 0xff)]
            body += b[r]
        }
        if !params.isEmpty && params != sets { sets = params; fmt = makeFormat(params) }
        guard let fmt, !body.isEmpty else { return nil }

        var block: CMBlockBuffer?
        let len = body.count
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: len,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: len, flags: 0, blockBufferOut: &block) == noErr, let block else { return nil }
        let st = body.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: len) }
        guard st == noErr else { return nil }

        var sb: CMSampleBuffer?
        var sizes = [len]
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: CMTimeValue(ms), timescale: 1000), decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: fmt, sampleCount: 1,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &sizes, sampleBufferOut: &sb) == noErr, let sb else { return nil }
        if let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(att) > 0 {
            let d = unsafeBitCast(CFArrayGetValueAtIndex(att, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(d, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            if !key {
                CFDictionarySetValue(d, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }
        return sb
    }

    private func makeFormat(_ p: [[UInt8]]) -> CMVideoFormatDescription? {
        var chosen: [[UInt8]] = []
        for t in (hevc ? [32, 33, 34] : [7, 8]) {
            guard let s = p.first(where: { !$0.isEmpty && type($0[0]) == t }) else { return nil }
            chosen.append(s)
        }
        let mem = chosen.map { s -> UnsafeMutablePointer<UInt8> in
            let m = UnsafeMutablePointer<UInt8>.allocate(capacity: s.count); m.initialize(from: s, count: s.count); return m
        }
        defer { mem.forEach { $0.deallocate() } }
        let ptrs = mem.map { UnsafePointer($0) }
        let sizes = chosen.map { $0.count }
        var desc: CMFormatDescription?
        let st: OSStatus
        if hevc {
            st = CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: chosen.count,
                    parameterSetPointers: ptrs, parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &desc)
        } else {
            st = CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: chosen.count,
                    parameterSetPointers: ptrs, parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &desc)
        }
        return st == noErr ? desc : nil
    }
}
