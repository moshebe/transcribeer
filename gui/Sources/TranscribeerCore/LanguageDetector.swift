import AVFoundation
import Foundation
import os.log
import WhisperKit

private let logger = Logger(subsystem: "com.transcribeer", category: "language-detector")

/// Detects a recording's spoken language before transcription, so `auto`
/// mode can route to a language-specific model (e.g. ivrit.ai for Hebrew).
///
/// Whisper only looks at 30 s per detection, and the first 30 s of a meeting
/// is often silence or small talk. Sampling a few windows across each source
/// and voting by confidence is much more reliable than a single probe.
public enum LanguageDetector {
    public struct Vote: Equatable, Sendable {
        public let language: String
        /// Probability (0...1) the model gave the detected language token.
        public let confidence: Float

        public init(language: String, confidence: Float) {
            self.language = language
            self.confidence = confidence
        }
    }

    static let windowSeconds = 30.0
    static let windowPositions = [0.1, 0.4, 0.7]
    /// ≈ -40 dBFS. Quieter windows are mostly room noise, which Whisper
    /// assigns a random language to.
    static let minWindowPeak: Float = 0.01

    public static func detect(audioURLs: [URL], kit: WhisperKit) async -> String? {
        var votes: [Vote] = []
        for url in audioURLs {
            for start in windowStarts(duration: duration(of: url)) {
                guard !Task.isCancelled else { return nil }
                guard let samples = loadWindow(url: url, start: start),
                      let peak = samples.map(abs).max(), peak >= minWindowPeak,
                      let result = try? await kit.detectLangauge(audioArray: samples),
                      let logProb = result.langProbs[result.language]
                else { continue }
                votes.append(Vote(language: result.language, confidence: exp(logProb)))
            }
        }
        let winner = tally(votes)
        let summary = votes.map { "\($0.language)=\(String(format: "%.2f", $0.confidence))" }
        logger.info(
            "votes=\(summary.joined(separator: " "), privacy: .public) winner=\(winner ?? "none", privacy: .public)"
        )
        return winner
    }

    /// Language with the highest summed confidence across all windows.
    static func tally(_ votes: [Vote]) -> String? {
        let scores = Dictionary(votes.map { ($0.language, $0.confidence) }, uniquingKeysWith: +)
        return scores.max { $0.value < $1.value }?.key
    }

    /// Window start offsets in seconds. Short recordings get one window from 0.
    static func windowStarts(duration: Double) -> [Double] {
        guard duration > windowSeconds * 2 else { return duration > 0 ? [0] : [] }
        return windowPositions.map { min($0 * duration, duration - windowSeconds) }
    }

    private static func duration(of url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private static func loadWindow(url: URL, start: Double) -> [Float]? {
        guard let buffer = try? AudioProcessor.loadAudio(
            fromPath: url.path,
            startTime: start,
            endTime: start + windowSeconds
        ) else { return nil }
        return AudioProcessor.convertBufferToArray(buffer: buffer)
    }
}
