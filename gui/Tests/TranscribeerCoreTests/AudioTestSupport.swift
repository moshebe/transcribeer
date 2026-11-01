import AVFoundation
import Testing

func decodedAudioDuration(_ url: URL) throws -> Double {
    let file = try AVAudioFile(forReading: url)
    let rate = file.processingFormat.sampleRate
    try #require(rate > 0)
    return Double(file.length) / rate
}
