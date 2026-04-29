import AVFoundation
import ScreenCaptureKit

public class AudioCapture: NSObject {
    public static let shared = AudioCapture()
    public override init() {}

    public var onStreamStopped: (() -> Void)?

    /// Whether to also capture the default microphone alongside system audio.
    /// When `true`, both sources are mixed and written to a single output file.
    /// When `false`, only system audio is captured (legacy behavior).
    public var captureMicrophone: Bool = true

    private var stream: SCStream?
    private var writer: AudioFileWriter?

    // Thread-safe accepting flag
    private let acceptingLock = NSLock()
    private var _accepting = true
    private var accepting: Bool {
        get { acceptingLock.withLock { _accepting } }
        set { acceptingLock.withLock { _accepting = newValue } }
    }

    private let dstFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    // One converter per source — different source formats (SC delivers system
    // audio at the stream config's rate; mic may deliver at its device's
    // native rate). Cached lazily from the first sample buffer of each type.
    private let converterLock = NSLock()
    private var sysConverter: AVAudioConverter?
    private var sysSrcFormat: AVAudioFormat?
    private var micConverter: AVAudioConverter?
    private var micSrcFormat: AVAudioFormat?

    // Per-source float32 sample queues. Emit mixed frames when both have data;
    // emit solo frames when one source has been idle past `orphanTimeout`.
    private let mixLock = NSLock()
    private var sysQueue: [Float] = []
    private var micQueue: [Float] = []
    private var lastSysArrival = Date.distantPast
    private var lastMicArrival = Date.distantPast
    private var orphanFlushTimer: DispatchSourceTimer?

    /// If only one source has been delivering samples for this long, flush the
    /// accumulated samples alone rather than waiting forever for the other.
    /// Handles the case where mic permission is denied (no mic samples ever
    /// arrive) or the user has no active audio input at all.
    private static let orphanTimeout: TimeInterval = 1.0

    public func start(writer: AudioFileWriter) async throws {
        self.writer = writer
        self.accepting = true
        converterLock.withLock {
            sysConverter = nil
            sysSrcFormat = nil
            micConverter = nil
            micSrcFormat = nil
        }
        mixLock.withLock {
            sysQueue.removeAll(keepingCapacity: true)
            micQueue.removeAll(keepingCapacity: true)
            lastSysArrival = Date.distantPast
            lastMicArrival = Date.distantPast
        }

        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(
            display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = false
        config.sampleRate = 48000
        config.channelCount = 2
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        if captureMicrophone, #available(macOS 15.0, *) {
            config.captureMicrophone = true
        }

        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(
            self, type: .audio,
            sampleHandlerQueue: DispatchQueue(label: "audio.capture.system"))

        if captureMicrophone, #available(macOS 15.0, *) {
            try s.addStreamOutput(
                self, type: .microphone,
                sampleHandlerQueue: DispatchQueue(label: "audio.capture.mic"))
        }

        try await s.startCapture()
        self.stream = s
        startOrphanFlushTimer()
    }

    public func stopAccepting() { accepting = false }

    public func stop() {
        stopAccepting()
        orphanFlushTimer?.cancel()
        orphanFlushTimer = nil
        let s = stream
        stream = nil
        let callback = onStreamStopped
        Task {
            try? await s?.stopCapture()
            flushAllRemaining()
            callback?()
        }
    }

    // MARK: - Mixing

    private func startOrphanFlushTimer() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "audio.capture.mixer"))
        timer.schedule(deadline: .now() + 0.5, repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.flushOrphansIfIdle() }
        timer.resume()
        orphanFlushTimer = timer
    }

    /// Drain whichever queue has been unmatched by its sibling for longer
    /// than `orphanTimeout`, so capture with only one active source (e.g. mic
    /// permission denied, or user not speaking and system audio silent) still
    /// produces an output file.
    private func flushOrphansIfIdle() {
        var orphan: [Float]?
        mixLock.withLock {
            let now = Date()
            let sysWaiting = now.timeIntervalSince(lastSysArrival) > Self.orphanTimeout
            let micWaiting = now.timeIntervalSince(lastMicArrival) > Self.orphanTimeout
            if micWaiting, !sysQueue.isEmpty {
                orphan = sysQueue
                sysQueue.removeAll(keepingCapacity: true)
            } else if sysWaiting, !micQueue.isEmpty {
                orphan = micQueue
                micQueue.removeAll(keepingCapacity: true)
            }
        }
        if let orphan { emitFloats(orphan) }
    }

    private func flushAllRemaining() {
        var emit: [Float] = []
        mixLock.withLock {
            // Mix whatever we can align
            let canMix = min(sysQueue.count, micQueue.count)
            if canMix > 0 {
                var mixed = [Float](repeating: 0, count: canMix)
                for i in 0..<canMix { mixed[i] = sysQueue[i] + micQueue[i] }
                sysQueue.removeFirst(canMix)
                micQueue.removeFirst(canMix)
                emit.append(contentsOf: mixed)
            }
            // Drain orphans as-is
            emit.append(contentsOf: sysQueue)
            emit.append(contentsOf: micQueue)
            sysQueue.removeAll()
            micQueue.removeAll()
        }
        if !emit.isEmpty { emitFloats(emit) }
    }

    /// Enqueue converted frames for the given source and emit any newly
    /// time-aligned mixed samples.
    private func enqueueAndMix(_ floats: [Float], isMic: Bool) {
        var mixedOut: [Float]?
        mixLock.withLock {
            let now = Date()
            if isMic {
                micQueue.append(contentsOf: floats)
                lastMicArrival = now
            } else {
                sysQueue.append(contentsOf: floats)
                lastSysArrival = now
            }
            let canMix = min(sysQueue.count, micQueue.count)
            guard canMix > 0 else { return }
            var mixed = [Float](repeating: 0, count: canMix)
            for i in 0..<canMix { mixed[i] = sysQueue[i] + micQueue[i] }
            sysQueue.removeFirst(canMix)
            micQueue.removeFirst(canMix)
            mixedOut = mixed
        }
        if let mixedOut { emitFloats(mixedOut) }
    }

    private func emitFloats(_ floats: [Float]) {
        guard !floats.isEmpty,
              let buf = AVAudioPCMBuffer(
                pcmFormat: dstFormat,
                frameCapacity: AVAudioFrameCount(floats.count),
              ) else { return }
        buf.frameLength = AVAudioFrameCount(floats.count)
        guard let channel = buf.floatChannelData?[0] else { return }
        // Hard-clip to [-1, 1] in case mixing pushed the sum past full scale.
        for i in 0..<floats.count {
            channel[i] = max(-1, min(1, floats[i]))
        }
        writer?.append(buf)
    }

    // MARK: - Sample-buffer decoding

    private func converterFor(_ srcFormat: AVAudioFormat, isMic: Bool) -> AVAudioConverter? {
        converterLock.withLock {
            if isMic {
                if let c = micConverter, micSrcFormat?.isEqual(srcFormat) == true { return c }
                guard let c = AVAudioConverter(from: srcFormat, to: dstFormat) else { return nil }
                micConverter = c
                micSrcFormat = srcFormat
                return c
            }
            if let c = sysConverter, sysSrcFormat?.isEqual(srcFormat) == true { return c }
            guard let c = AVAudioConverter(from: srcFormat, to: dstFormat) else { return nil }
            sysConverter = c
            sysSrcFormat = srcFormat
            return c
        }
    }

    /// Decode a CMSampleBuffer to 16 kHz mono float32 samples.
    private func decodeToFloats(_ sampleBuffer: CMSampleBuffer, isMic: Bool) -> [Float]? {
        let numFrames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numFrames > 0 else { return nil }

        guard let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let srcFormat = AVAudioFormat(cmAudioFormatDescription: fmtDesc)

        guard let conv = converterFor(srcFormat, isMic: isMic) else { return nil }

        // Allocate an ABL sized to the sample buffer's actual audio data.
        var ablSizeNeeded = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &ablSizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: nil,
        )
        guard ablSizeNeeded > 0 else { return nil }

        let ablPtr = UnsafeMutableRawPointer.allocate(
            byteCount: ablSizeNeeded,
            alignment: MemoryLayout<AudioBufferList>.alignment,
        )
        defer { ablPtr.deallocate() }
        let abl = ablPtr.bindMemory(to: AudioBufferList.self, capacity: 1)

        var blockRef: CMBlockBuffer?
        let fillStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: abl,
            bufferListSize: ablSizeNeeded,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockRef,
        )
        guard fillStatus == noErr else { return nil }

        // Copy ABL data into an AVAudioPCMBuffer via its own buffer list.
        guard let srcBuf = AVAudioPCMBuffer(
            pcmFormat: srcFormat,
            frameCapacity: AVAudioFrameCount(numFrames),
        ) else { return nil }
        srcBuf.frameLength = AVAudioFrameCount(numFrames)

        let dstABL = srcBuf.mutableAudioBufferList
        withUnsafeMutablePointer(to: &abl.pointee.mBuffers) { srcStart in
            let srcBuffers = UnsafeBufferPointer<AudioBuffer>(
                start: srcStart, count: Int(abl.pointee.mNumberBuffers),
            )
            let dstMutableABL = UnsafeMutableAudioBufferListPointer(dstABL)
            for (i, srcEntry) in srcBuffers.enumerated() {
                guard i < dstMutableABL.count,
                      let srcData = srcEntry.mData,
                      let dstData = dstMutableABL[i].mData else { continue }
                let copyBytes = min(Int(srcEntry.mDataByteSize), Int(dstMutableABL[i].mDataByteSize))
                memcpy(dstData, srcData, copyBytes)
            }
        }

        // Convert to 16 kHz mono.
        let ratio = dstFormat.sampleRate / srcFormat.sampleRate
        let outFrames = AVAudioFrameCount(ceil(Double(numFrames) * ratio)) + 1
        guard let dstBuf = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: outFrames) else { return nil }

        var convError: NSError?
        conv.convert(to: dstBuf, error: &convError) { _, outStatus in
            outStatus.pointee = .haveData
            return srcBuf
        }
        guard convError == nil, dstBuf.frameLength > 0 else { return nil }

        let count = Int(dstBuf.frameLength)
        guard let ptr = dstBuf.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: ptr, count: count))
    }
}

public enum CaptureError: Error {
    case noDisplay
}

extension AudioCapture: SCStreamDelegate {
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Stream was stopped externally (e.g. "Stop sharing" button)
        stopAccepting()
        onStreamStopped?()
    }
}

extension AudioCapture: SCStreamOutput {
    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType,
    ) {
        guard accepting else { return }
        let isMic: Bool
        switch type {
        case .audio: isMic = false
        case .microphone: isMic = true
        default: return
        }
        guard let floats = decodeToFloats(sampleBuffer, isMic: isMic) else { return }
        enqueueAndMix(floats, isMic: isMic)
    }
}
