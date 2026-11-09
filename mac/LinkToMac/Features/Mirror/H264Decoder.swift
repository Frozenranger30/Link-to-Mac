import AVFoundation
import CoreMedia
import Foundation

/// Turns Annex-B H.264 into CMSampleBuffers for an AVSampleBufferDisplayLayer, which decodes
/// them with VideoToolbox in hardware.
final class H264Decoder {
    let layer = AVSampleBufferDisplayLayer()
    var onSize: ((CGSize) -> Void)?

    private var sps: Data?
    private var pps: Data?
    private var format: CMVideoFormatDescription?

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    func reset() {
        sps = nil
        pps = nil
        format = nil
        DispatchQueue.main.async { self.layer.flushAndRemoveImage() }
    }

    /// Splits Annex-B data into NAL units (without start codes).
    static func nalUnits(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var starts: [(Int, Int)] = [] // (startCodeIndex, payloadIndex)
        var i = 0
        while i + 3 <= bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 {
                    starts.append((i, i + 3)); i += 3; continue
                }
                if i + 4 <= bytes.count, bytes[i + 2] == 0, bytes[i + 3] == 1 {
                    starts.append((i, i + 4)); i += 4; continue
                }
            }
            i += 1
        }
        return starts.enumerated().map { idx, s in
            let end = idx + 1 < starts.count ? starts[idx + 1].0 : bytes.count
            return Data(bytes[s.1..<end])
        }
    }

    /// Call on a serial queue.
    func decode(_ annexB: Data) {
        var avcc = Data()
        var newSps: Data?
        var newPps: Data?
        for nal in Self.nalUnits(annexB) where !nal.isEmpty {
            let type = nal[nal.startIndex] & 0x1f
            switch type {
            case 7: newSps = nal
            case 8: newPps = nal
            case 9: continue // access unit delimiter
            default:
                var len = UInt32(nal.count).bigEndian
                avcc.append(Data(bytes: &len, count: 4))
                avcc.append(nal)
            }
        }
        if let s = newSps ?? sps, let p = newPps ?? pps, newSps != nil || newPps != nil {
            if s != sps || p != pps || format == nil {
                sps = s
                pps = p
                makeFormat()
            }
        }
        guard !avcc.isEmpty, let format, let sample = makeSample(avcc, format: format) else { return }
        DispatchQueue.main.async {
            if self.layer.status == .failed { self.layer.flush() }
            self.layer.enqueue(sample)
        }
    }

    private func makeFormat() {
        guard let sps, let pps else { return }
        var fmt: CMFormatDescription?
        let status: OSStatus = sps.withUnsafeBytes { spsRaw in
            pps.withUnsafeBytes { ppsRaw in
                guard let spsPtr = spsRaw.bindMemory(to: UInt8.self).baseAddress,
                      let ppsPtr = ppsRaw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                let pointers: [UnsafePointer<UInt8>] = [spsPtr, ppsPtr]
                let sizes: [Int] = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &fmt
                )
            }
        }
        guard status == noErr, let fmt else { return }
        format = fmt
        let dims = CMVideoFormatDescriptionGetDimensions(fmt)
        let size = CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))
        DispatchQueue.main.async { self.onSize?(size) }
    }

    private func makeSample(_ avcc: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        let count = avcc.count
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: count, flags: 0, blockBufferOut: &block
        ) == kCMBlockBufferNoErr, let block else { return nil }
        let copied: OSStatus = avcc.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: count)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        var sample: CMSampleBuffer?
        var size = count
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample
        ) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}
