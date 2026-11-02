import CoreAudio
import Dispatch
import os

private let logger = Logger(subsystem: "com.transcribeer", category: "AudioPropertyListener")

/// Registers a Core Audio property listener block and removes it on
/// `invalidate()` or deinit, so callers can't leak a listener that fires into
/// a torn-down capture.
final class AudioPropertyListener: @unchecked Sendable {
    private let objectID: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private var block: AudioObjectPropertyListenerBlock?

    /// Returns nil when Core Audio refuses the listener (e.g. the object is
    /// gone); the failure is logged.
    init?(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) {
        self.objectID = objectID
        self.queue = queue
        address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        let status = AudioObjectAddPropertyListenerBlock(objectID, &address, queue, block)
        guard status == noErr else {
            logger.error(
                "add listener failed object=\(objectID, privacy: .public) status=\(status, privacy: .public)"
            )
            return nil
        }
        self.block = block
    }

    func invalidate() {
        guard let block else { return }
        AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, block)
        self.block = nil
    }

    deinit {
        invalidate()
    }
}
