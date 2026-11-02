import AVFoundation

/// A captured PCM buffer tagged with the capture generation that produced it.
///
/// The generation increases every time a capture is rebuilt after an audio
/// route change. Carrying it in-band lets the writer detect the rebuild gap
/// exactly at the first buffer from the new capture, even when buffers from
/// the old one are still queued in the stream.
public struct CapturedBuffer: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer
    public let generation: Int
}
