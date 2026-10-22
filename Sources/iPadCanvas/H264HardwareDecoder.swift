import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

final class H264HardwareDecoder {
    var onDecodedPixelBuffer: ((CVPixelBuffer) -> Void)?

    private var spsData: Data?
    private var ppsData: Data?
    private var formatDescription: CMVideoFormatDescription?
    private var decompressionSession: VTDecompressionSession?
    private let decodeLock = NSLock()

    deinit {
        invalidateSession()
    }

    func reset() {
        decodeLock.lock()
        defer { decodeLock.unlock() }
        invalidateSessionLocked()
        spsData = nil
        ppsData = nil
    }

    private func invalidateSession() {
        decodeLock.lock()
        defer { decodeLock.unlock() }
        invalidateSessionLocked()
    }

    private func invalidateSessionLocked() {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }
        formatDescription = nil
    }

    func decodeAnnexB(data: UnsafePointer<UInt8>, length: Int) {
        guard length > 4 else { return }

        decodeLock.lock()
        defer { decodeLock.unlock() }

        // Find all 4-byte (0x00 0x00 0x00 0x01) and 3-byte (0x00 0x00 0x01) start code boundaries
        var nalStarts: [(start: Int, prefixLen: Int)] = []
        var i = 0
        while i < length - 2 {
            if data[i] == 0 && data[i + 1] == 0 {
                if i + 3 < length && data[i + 2] == 0 && data[i + 3] == 1 {
                    nalStarts.append((start: i, prefixLen: 4))
                    i += 4
                    continue
                } else if data[i + 2] == 1 {
                    nalStarts.append((start: i, prefixLen: 3))
                    i += 3
                    continue
                }
            }
            i += 1
        }

        guard !nalStarts.isEmpty else { return }

        var formatChanged = false
        var avccData = Data()
        var hasVCL = false

        for idx in 0..<nalStarts.count {
            let start = nalStarts[idx].start + nalStarts[idx].prefixLen
            let end = (idx + 1 < nalStarts.count) ? nalStarts[idx + 1].start : length
            let nalLen = end - start
            guard nalLen > 0 else { continue }

            let nalPtr = data.advanced(by: start)
            let header = nalPtr[0]
            if (header & 0x80) != 0 {
                // Forbidden zero bit must be 0 for valid H.264 NAL
                continue
            }

            let nalType = header & 0x1F
            switch nalType {
            case 7: // SPS
                let newSPS = Data(bytes: nalPtr, count: nalLen)
                if spsData != newSPS {
                    spsData = newSPS
                    formatChanged = true
                }
            case 8: // PPS
                let newPPS = Data(bytes: nalPtr, count: nalLen)
                if ppsData != newPPS {
                    ppsData = newPPS
                    formatChanged = true
                }
            case 1, 5, 6, 14: // Non-IDR Slice, IDR Slice, SEI, or Prefix NAL
                var bigEndianLen = UInt32(nalLen).bigEndian
                withUnsafeBytes(of: &bigEndianLen) { avccData.append(contentsOf: $0) }
                avccData.append(nalPtr, count: nalLen)
                if nalType == 1 || nalType == 5 {
                    hasVCL = true
                }
            default:
                break
            }
        }

        if formatChanged || decompressionSession == nil {
            if let sps = spsData, let pps = ppsData {
                _ = configureDecompressionSessionLocked(sps: sps, pps: pps)
            }
        }

        guard hasVCL,
              !avccData.isEmpty,
              let formatDesc = formatDescription,
              let session = decompressionSession else {
            return
        }

        decodeAVCCFrameLocked(avccData: avccData, formatDescription: formatDesc, session: session)
    }

    private func configureDecompressionSessionLocked(sps: Data, pps: Data) -> Bool {
        invalidateSessionLocked()

        var newFormatDesc: CMFormatDescription?
        let status: OSStatus = sps.withUnsafeBytes { spsRaw in
            pps.withUnsafeBytes { ppsRaw in
                guard let spsBase = spsRaw.bindMemory(to: UInt8.self).baseAddress,
                      let ppsBase = ppsRaw.bindMemory(to: UInt8.self).baseAddress else {
                    return kCMFormatDescriptionError_InvalidParameter
                }
                let pointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                let sizes: [Int] = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &newFormatDesc
                )
            }
        }

        guard status == noErr, let formatDesc = newFormatDesc else {
            print("[Decoder] CMVideoFormatDescriptionCreateFromH264ParameterSets failed: \(status)")
            return false
        }
        self.formatDescription = formatDesc

        let decoderSpec: [CFString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: kCFBooleanTrue!
        ]

        let destAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: kCFBooleanTrue!
        ]

        var sessionOut: VTDecompressionSession?
        let createStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDesc,
            decoderSpecification: decoderSpec as CFDictionary,
            imageBufferAttributes: destAttributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &sessionOut
        )

        guard createStatus == noErr, let session = sessionOut else {
            print("[Decoder] VTDecompressionSessionCreate failed: \(createStatus)")
            return false
        }

        VTSessionSetProperty(
            session,
            key: kVTDecompressionPropertyKey_RealTime,
            value: kCFBooleanTrue
        )

        self.decompressionSession = session
        return true
    }

    private func decodeAVCCFrameLocked(
        avccData: Data,
        formatDescription: CMVideoFormatDescription,
        session: VTDecompressionSession
    ) {
        let dataCount = avccData.count
        guard dataCount > 0 else { return }

        var blockBufferOut: CMBlockBuffer?
        let createBlockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataCount,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBufferOut
        )

        guard createBlockStatus == kCMBlockBufferNoErr, let blockBuffer = blockBufferOut else {
            print("[Decoder] CMBlockBufferCreate failed: \(createBlockStatus)")
            return
        }

        let replaceStatus = avccData.withUnsafeBytes { rawPtr -> OSStatus in
            guard let base = rawPtr.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: dataCount
            )
        }

        guard replaceStatus == kCMBlockBufferNoErr else {
            print("[Decoder] CMBlockBufferReplaceDataBytes failed: \(replaceStatus)")
            return
        }

        var sampleBufferOut: CMSampleBuffer?
        var sampleSize = dataCount
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBufferOut
        )

        guard sampleStatus == noErr, let sampleBuffer = sampleBufferOut else {
            print("[Decoder] CMSampleBufferCreateReady failed: \(sampleStatus)")
            return
        }

        var infoFlags = VTDecodeInfoFlags()
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [],
            infoFlagsOut: &infoFlags
        ) { [weak self] status, _, imageBuffer, _, _ in
            guard status == noErr, let pixelBuffer = imageBuffer else {
                if status != noErr {
                    print("[Decoder] VTDecompressionSessionDecodeFrame failed: \(status)")
                }
                return
            }
            self?.onDecodedPixelBuffer?(pixelBuffer)
        }

        if decodeStatus != noErr {
            print("[Decoder] VTDecompressionSessionDecodeFrame invocation failed: \(decodeStatus)")
        }
    }
}
