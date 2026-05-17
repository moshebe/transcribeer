import TranscribeerCore
import AVFoundation
import SwiftUI

// MARK: - View Model

@Observable
@MainActor
final class AudioPlayerVM {
    private(set) var isPlaying = false
    private(set) var duration: TimeInterval = 0
    var currentTime: TimeInterval = 0
    var rate: Float = 1.0

    /// Normalized (0...1) amplitude peaks across the recording. Empty until
    /// `loadWaveform` finishes. One value per bucket, linearly spaced over
    /// the file's duration.
    private(set) var waveformSamples: [Float] = []
    private(set) var waveformLoading = false
    private var waveformURL: URL?
    private var waveformTask: Task<Void, Never>?

    private var player: AVAudioPlayer?
    private var tickerTask: Task<Void, Never>?

    var hasAudio: Bool { player != nil }

    func load(url: URL) {
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.enableRate = true
        p.prepareToPlay()
        player = p
        duration = p.duration
        currentTime = 0
        loadWaveform(url: url)
    }

    private func loadWaveform(url: URL, buckets: Int = 400) {
        waveformURL = url
        waveformLoading = true
        waveformTask?.cancel()
        waveformTask = Task { [weak self] in
            let peaks = await Task.detached(priority: .userInitiated) {
                WaveformSampler.samples(url: url, buckets: buckets)
            }.value
            guard !Task.isCancelled, let self, self.waveformURL == url else { return }
            self.waveformSamples = peaks
            self.waveformLoading = false
        }
    }

    func togglePlay() {
        guard let p = player else { return }
        if isPlaying {
            pause()
        } else {
            p.rate = rate
            p.play()
            isPlaying = true
            startTicker()
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTicker()
    }

    func stop() {
        player?.stop()
        isPlaying = false
        stopTicker()
        player = nil
        duration = 0
        currentTime = 0
        waveformTask?.cancel()
        waveformTask = nil
        waveformURL = nil
        waveformSamples = []
        waveformLoading = false
    }

    func seek(to time: TimeInterval) {
        guard let p = player else { return }
        let clamped = max(0, min(time, duration))
        p.currentTime = clamped
        currentTime = clamped
    }

    func skip(_ delta: TimeInterval) {
        seek(to: currentTime + delta)
    }

    func setRate(_ newRate: Float) {
        rate = newRate
        if isPlaying {
            player?.rate = newRate
        }
    }

    private func startTicker() {
        tickerTask?.cancel()
        tickerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self, let p = self.player else { return }
                self.currentTime = p.currentTime
                if !p.isPlaying && self.isPlaying {
                    self.isPlaying = false
                    return
                }
            }
        }
    }

    private func stopTicker() {
        tickerTask?.cancel()
        tickerTask = nil
    }
}

// MARK: - View

struct AudioPlayerView: View {
    let audioURL: URL
    /// Shared player instance. Owned by the parent so siblings (e.g. the
    /// transcript view's clickable timestamps) can drive playback too.
    let vm: AudioPlayerVM
    /// Invoked when the user confirms a split at the current playhead.
    /// `nil` hides the split button (e.g. when the parent has nothing
    /// sensible to do with the split — imports before a session is saved).
    var onSplit: ((TimeInterval) -> Void)?

    @State private var showSplitConfirm = false

    private static let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
    /// Keep the playhead at least this far from either edge before we allow a
    /// split — matches `SessionSplitter.minEdgeDistance` so clicking the
    /// button can never produce a zero-length or full-length split.
    private static let minSplitEdgeDistance: TimeInterval = 1.0

    var body: some View {
        VStack(spacing: 6) {
            // Waveform scrubber
            GeometryReader { geo in
                WaveformBar(
                    samples: vm.waveformSamples,
                    progress: progressFraction,
                    isLoading: vm.waveformLoading
                )
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let fraction = max(0, min(1, value.location.x / geo.size.width))
                            vm.currentTime = fraction * vm.duration
                        }
                        .onEnded { value in
                            let fraction = max(0, min(1, value.location.x / geo.size.width))
                            vm.seek(to: fraction * vm.duration)
                        }
                )
            }
            .frame(height: 40)
            .accessibilityLabel("Playback position")
            .accessibilityValue("\(formatTime(vm.currentTime)) of \(formatTime(vm.duration))")

            // Controls row
            HStack(spacing: 8) {
                // Elapsed / Duration
                Text(formatTime(vm.currentTime))
                    .monospacedDigit()
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .leading)

                Spacer()

                Button { vm.skip(-10) } label: {
                    Image(systemName: "gobackward.10")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .disabled(!vm.hasAudio)
                .accessibilityLabel("Skip back 10 seconds")

                Button { vm.togglePlay() } label: {
                    Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .disabled(!vm.hasAudio)
                .keyboardShortcut(.space, modifiers: [])
                .accessibilityLabel(vm.isPlaying ? "Pause" : "Play")

                Button { vm.skip(30) } label: {
                    Image(systemName: "goforward.30")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .disabled(!vm.hasAudio)
                .accessibilityLabel("Skip forward 30 seconds")

                if onSplit != nil {
                    Button { showSplitConfirm = true } label: {
                        Image(systemName: "scissors")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSplit)
                    .help(splitHelpText)
                    .accessibilityLabel("Split recording at current time")
                }

                Spacer()

                // Speed picker
                Menu {
                    ForEach(Self.speeds, id: \.self) { speed in
                        Button {
                            vm.setRate(speed)
                        } label: {
                            HStack {
                                Text(speedLabel(speed))
                                if vm.rate == speed {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Text(speedLabel(vm.rate))
                        .font(.caption2.weight(.medium))
                        .monospacedDigit()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Playback speed")
                .accessibilityLabel("Playback speed")
                .accessibilityValue(speedLabel(vm.rate))

                Text(formatTime(vm.duration))
                    .monospacedDigit()
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .onAppear { vm.load(url: audioURL) }
        .onChange(of: audioURL) { _, newURL in vm.load(url: newURL) }
        .onDisappear { vm.stop() }
        .confirmationDialog(
            "Split recording at \(formatTime(vm.currentTime))?",
            isPresented: $showSplitConfirm,
            titleVisibility: .visible,
        ) {
            Button("Split") {
                vm.pause()
                onSplit?(vm.currentTime)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything after \(formatTime(vm.currentTime)) is moved to a new session. The original keeps the first \(formatTime(vm.currentTime)).")
        }
    }

    private var canSplit: Bool {
        vm.hasAudio
            && vm.duration > Self.minSplitEdgeDistance * 2
            && vm.currentTime >= Self.minSplitEdgeDistance
            && vm.currentTime <= vm.duration - Self.minSplitEdgeDistance
    }

    private var splitHelpText: String {
        canSplit
            ? "Split recording here (\(formatTime(vm.currentTime)))"
            : "Move the playhead away from the start or end to split"
    }

    private var progressFraction: Double {
        guard vm.duration > 0 else { return 0 }
        return max(0, min(1, vm.currentTime / vm.duration))
    }

    private func speedLabel(_ speed: Float) -> String {
        speed == 1.0 ? "1x" : String(format: "%gx", speed)
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let total = max(0, Int(t))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Waveform Bar

private struct WaveformBar: View {
    let samples: [Float]
    let progress: Double
    let isLoading: Bool

    var body: some View {
        Canvas { context, size in
            drawBackground(context: context, size: size)
            if samples.isEmpty {
                drawPlaceholder(context: context, size: size)
            } else {
                drawBars(context: context, size: size)
            }
            drawPlayhead(context: context, size: size)
        }
    }

    private func drawBackground(context: GraphicsContext, size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        context.fill(
            Path(roundedRect: rect, cornerRadius: 4),
            with: .color(Color.primary.opacity(0.04))
        )
    }

    private func drawPlaceholder(context: GraphicsContext, size: CGSize) {
        let midY = size.height / 2
        var path = Path()
        path.move(to: CGPoint(x: 0, y: midY))
        path.addLine(to: CGPoint(x: size.width, y: midY))
        context.stroke(
            path,
            with: .color(Color.secondary.opacity(isLoading ? 0.35 : 0.25)),
            lineWidth: 1
        )
    }

    private func drawBars(context: GraphicsContext, size: CGSize) {
        let count = samples.count
        let step = size.width / CGFloat(count)
        let barWidth = max(1, step - 1)
        let midY = size.height / 2
        let maxHalf = size.height / 2 - 1
        let playedColor = Color.accentColor
        let unplayedColor = Color.secondary.opacity(0.55)

        for (i, sample) in samples.enumerated() {
            let x = CGFloat(i) * step
            let half = max(0.5, CGFloat(sample) * maxHalf)
            let rect = CGRect(x: x, y: midY - half, width: barWidth, height: half * 2)
            let fraction = (Double(i) + 0.5) / Double(count)
            let color = fraction <= progress ? playedColor : unplayedColor
            context.fill(
                Path(roundedRect: rect, cornerRadius: barWidth / 2),
                with: .color(color)
            )
        }
    }

    private func drawPlayhead(context: GraphicsContext, size: CGSize) {
        guard progress > 0, progress < 1 else { return }
        let x = size.width * CGFloat(progress)
        var line = Path()
        line.move(to: CGPoint(x: x, y: 0))
        line.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(line, with: .color(Color.accentColor), lineWidth: 1)
    }
}

// MARK: - Waveform Sampler

enum WaveformSampler {
    /// Computes `buckets` normalized peak amplitudes across the audio file.
    /// Reads the file in chunks to bound memory for long recordings.
    static func samples(url: URL, buckets: Int) -> [Float] {
        guard buckets > 0 else { return [] }
        do {
            let file = try AVAudioFile(forReading: url)
            let totalFrames = file.length
            guard totalFrames > 0 else { return [] }

            let format = file.processingFormat
            let bucketFrames = max(AVAudioFrameCount(1), AVAudioFrameCount(totalFrames / Int64(buckets)))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: bucketFrames) else {
                return []
            }

            var peaks: [Float] = []
            peaks.reserveCapacity(buckets)
            var globalMax: Float = 0.0001

            for _ in 0..<buckets {
                buffer.frameLength = 0
                do {
                    try file.read(into: buffer, frameCount: bucketFrames)
                } catch {
                    break
                }
                if buffer.frameLength == 0 { break }
                let peak = bucketPeak(buffer: buffer)
                peaks.append(peak)
                if peak > globalMax { globalMax = peak }
            }

            return peaks.map { min(1, $0 / globalMax) }
        } catch {
            return []
        }
    }

    private static func bucketPeak(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        var peak: Float = 0
        for channel in 0..<channels {
            let data = channelData[channel]
            for frame in 0..<frames {
                let v = abs(data[frame])
                if v > peak { peak = v }
            }
        }
        return peak
    }
}
