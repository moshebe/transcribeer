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

    private var player: AVAudioPlayer?
    private var ticker: Timer?

    var hasAudio: Bool { player != nil }

    func load(url: URL) {
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.enableRate = true
        p.prepareToPlay()
        player = p
        duration = p.duration
        currentTime = 0
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
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let p = self.player else { return }
                self.currentTime = p.currentTime
                if !p.isPlaying && self.isPlaying {
                    self.isPlaying = false
                    self.stopTicker()
                }
            }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }
}

// MARK: - View

struct AudioPlayerView: View {
    let audioURL: URL
    @State private var vm = AudioPlayerVM()
    @State private var isSeeking = false

    private static let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
        VStack(spacing: 6) {
            // Waveform-style progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.quaternary)

                    RoundedRectangle(cornerRadius: 3)
                        .fill(.tint)
                        .frame(width: progressWidth(in: geo.size.width))
                }
                .frame(height: 6)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isSeeking = true
                            let fraction = max(0, min(1, value.location.x / geo.size.width))
                            vm.currentTime = fraction * vm.duration
                        }
                        .onEnded { value in
                            let fraction = max(0, min(1, value.location.x / geo.size.width))
                            vm.seek(to: fraction * vm.duration)
                            isSeeking = false
                        }
                )
            }
            .frame(height: 6)

            // Controls row
            HStack(spacing: 8) {
                // Elapsed / Duration
                Text(formatTime(vm.currentTime))
                    .monospacedDigit()
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .leading)

                Spacer()

                // Skip back 10s
                Button { vm.skip(-10) } label: {
                    Image(systemName: "gobackward.10")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .disabled(!vm.hasAudio)

                // Play/Pause
                Button { vm.togglePlay() } label: {
                    Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .disabled(!vm.hasAudio)
                .keyboardShortcut(.space, modifiers: [])

                // Skip forward 30s
                Button { vm.skip(30) } label: {
                    Image(systemName: "goforward.30")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .disabled(!vm.hasAudio)

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
    }

    private func progressWidth(in totalWidth: CGFloat) -> CGFloat {
        guard vm.duration > 0 else { return 0 }
        return totalWidth * CGFloat(vm.currentTime / vm.duration)
    }

    private func speedLabel(_ speed: Float) -> String {
        speed == 1.0 ? "1×" : String(format: "%g×", speed)
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let total = max(0, Int(t))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
