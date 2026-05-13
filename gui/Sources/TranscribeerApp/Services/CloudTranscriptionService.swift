import Foundation
import os.log
import TranscribeerCore

/// Type alias chosen to match the Core layer because cloud results feed into
/// `DualSourceTranscriber.mergeAndTag` which expects `TranscribeerCore.TranscriptSegment`.
/// Using the alias avoids ambiguity with the App-layer `TranscriptSegment`
/// defined in `TranscriptionService.swift`.
typealias CoreSegment = TranscribeerCore.TranscriptSegment

/// Calls cloud transcription APIs (OpenAI, Gemini) for a single audio file
/// and returns timestamped segments compatible with the local WhisperKit path.
///
/// Long files are split with `AudioChunker` (10-min WAV chunks) and the API
/// is called in parallel for each chunk; per-chunk timestamps are then
/// shifted by the chunk's `startOffset` so the final segment list lives in
/// the original recording's timeline.
///
/// Failure modes returned via `TranscriptionError` so the UI can surface
/// actionable messages (missing key, bad response, HTTP error).
enum CloudTranscriptionService {
    private static let logger = Logger(
        subsystem: "com.transcribeer", category: "CloudTranscription"
    )

    /// Maximum API calls running at once per source. Both OpenAI and Gemini
    /// rate-limit by RPM; 3 keeps us well below typical free-tier ceilings
    /// while still parallelising a multi-chunk recording.
    private static let maxConcurrency = 3

    /// Chunk length (seconds). Matches `ChunkedTranscriber`. Combined with
    /// `uploadSampleRate` (16 kHz) and `uploadFormat` (AAC-LC @ 48 kbps),
    /// a 10-min chunk is ~3.6 MB on the wire — well under OpenAI's 25 MB
    /// request cap with room for an outlier chunk near the chunk-duration
    /// boundary.
    private static let chunkSeconds: Double = 600

    /// Sample rate used for upload-ready chunks. 16 kHz is Whisper's native
    /// rate, so the cloud model spends no work re-resampling.
    private static let uploadSampleRate: Double = 16_000

    /// Container/codec used for upload-ready chunks. AAC-LC mono at
    /// 48 kbps gives a ~5× size reduction over 16 kHz Int16 WAV (3.6 MB vs
    /// 19 MB for a 10-min chunk) with no measurable accuracy hit on
    /// Whisper / gpt-4o-transcribe. OpenAI's audio API accepts `m4a` as
    /// a documented supported format.
    private static let uploadFormat: AudioChunker.OutputFormat = .aacM4A(bitrate: 48_000)

    /// MIME type that matches `uploadFormat`. Used by OpenAI's multipart
    /// upload and Gemini's `inline_data` block (declared `fileprivate` so
    /// the two backend-specific enums later in this file can reach it).
    /// Kept in sync with the format constant so updating one doesn't
    /// silently desync the wire format from the Content-Type the server
    /// expects.
    fileprivate static let uploadMimeType = "audio/m4a"

    /// Transcribe `audioURL` using the given cloud backend.
    ///
    /// - Parameters:
    ///   - backend: `.openai` or `.gemini`. `.whisperkit` returns an empty
    ///     array — the caller is expected to route locally.
    ///   - audioURL: Path to the per-source audio (mic.caf / sys.caf / m4a).
    ///   - model: Cloud model id (e.g. "whisper-1", "gemini-2.5-flash").
    ///   - language: Whisper-style language code or "auto".
    ///   - onProgress: Receives a `CloudProgressTracker.Snapshot` whenever
    ///     progress changes meaningfully (smoothed at ~4 Hz). Contains both
    ///     the fraction and the per-chunk counts so the UI can show
    ///     "Transcribing N of M chunks" alongside the bar.
    static func transcribe(
        backend: TranscriptionBackend,
        audioURL: URL,
        model: String,
        language: String,
        onProgress: (@Sendable (CloudProgressTracker.Snapshot) -> Void)? = nil
    ) async throws -> [CoreSegment] {
        guard backend != .whisperkit else { return [] }
        let apiKey = try requireAPIKey(for: backend)

        let fileSize = (try? FileManager.default
            .attributesOfItem(atPath: audioURL.path)[.size] as? Int) ?? -1
        logger.info(
            """
            transcribe start backend=\(backend.rawValue, privacy: .public) \
            model=\(model, privacy: .public) \
            lang=\(language, privacy: .public) \
            file=\(audioURL.lastPathComponent, privacy: .public) \
            bytes=\(fileSize, privacy: .public)
            """
        )

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribeer-cloud-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let chunks = try AudioChunker.split(
            source: audioURL,
            chunkDuration: chunkSeconds,
            targetSampleRate: uploadSampleRate,
            outputFormat: uploadFormat,
            tempDir: tempDir
        )
        guard !chunks.isEmpty else {
            logger.info(
                "transcribe: no chunks produced for \(audioURL.lastPathComponent, privacy: .public)"
            )
            return []
        }

        let total = chunks.count
        let tracker = CloudProgressTracker(
            total: total,
            audioSecondsPerChunk: chunkSeconds,
            emit: onProgress
        )
        tracker.start()
        defer { tracker.stop() }

        let langCode: String? = language == "auto" ? nil : language
        logger.info(
            """
            transcribe chunks=\(total, privacy: .public) \
            chunkSeconds=\(Int(chunkSeconds), privacy: .public) \
            concurrency=\(maxConcurrency, privacy: .public)
            """
        )

        // Process in fixed-size batches so long recordings don't fan out
        // hundreds of concurrent API calls. Within a batch we use a
        // throwing task group — first error cancels the rest. Chunks are
        // enumerated up-front so each task carries its global index and
        // can report start/done to the tracker independently.
        let batchSize = min(maxConcurrency, total)
        var combined: [CoreSegment] = []
        // Relabel `(offset:, element:)` from `enumerated()` to the more
        // readable `(index:, chunk:)` used by the helpers below.
        let indexed = chunks.enumerated().map { (index: $0.offset, chunk: $0.element) }
        let batches = stride(from: 0, to: total, by: batchSize).map { start in
            Array(indexed[start..<min(start + batchSize, total)])
        }

        let ctx = ChunkContext(
            backend: backend, model: model, language: langCode, apiKey: apiKey
        )
        for batch in batches {
            let results = try await runBatch(batch: batch, ctx: ctx, tracker: tracker)
            combined.append(contentsOf: results)
        }
        return combined.sorted { $0.start < $1.start }
    }

    /// Shared per-call context threaded through the batch/chunk helpers so
    /// each helper stays under the positional-parameter cap.
    private struct ChunkContext: Sendable {
        let backend: TranscriptionBackend
        let model: String
        let language: String?
        let apiKey: String
    }

    /// Run one batch of chunks concurrently. First error cancels the rest
    /// (throwing task group semantics). `batch` carries the chunk's global
    /// index so the tracker can attribute start/done events to the right
    /// slot regardless of intra-batch scheduling order.
    private static func runBatch(
        batch: [(index: Int, chunk: AudioChunker.Chunk)],
        ctx: ChunkContext,
        tracker: CloudProgressTracker
    ) async throws -> [CoreSegment] {
        try await withThrowingTaskGroup(of: [CoreSegment].self) { group in
            for entry in batch {
                group.addTask {
                    try await runChunk(
                        index: entry.index, chunk: entry.chunk, ctx: ctx, tracker: tracker
                    )
                }
            }
            var acc: [CoreSegment] = []
            for try await batchResult in group { acc.append(contentsOf: batchResult) }
            return acc
        }
    }

    /// Transcribe a single chunk and log start/done/failure with the
    /// offset and backend/model so failures can be pinpointed to a
    /// specific slice of the original audio. The tracker is poked twice
    /// — once when the API call begins, once on success — so the heartbeat
    /// can interpolate progress over the chunk's wall time.
    private static func runChunk(
        index: Int,
        chunk: AudioChunker.Chunk,
        ctx: ChunkContext,
        tracker: CloudProgressTracker
    ) async throws -> [CoreSegment] {
        try Task.checkCancellation()
        let chunkBytes = (try? FileManager.default
            .attributesOfItem(atPath: chunk.url.path)[.size] as? Int) ?? -1
        logger.debug(
            """
            chunk start backend=\(ctx.backend.rawValue, privacy: .public) \
            offset=\(chunk.startOffset, privacy: .public) \
            bytes=\(chunkBytes, privacy: .public) \
            file=\(chunk.url.lastPathComponent, privacy: .public)
            """
        )
        tracker.markStarted(index)
        let segs: [CoreSegment]
        do {
            segs = try await transcribeChunk(
                backend: ctx.backend,
                chunkURL: chunk.url,
                model: ctx.model,
                language: ctx.language,
                apiKey: ctx.apiKey
            )
        } catch {
            logger.error(
                """
                chunk failed backend=\(ctx.backend.rawValue, privacy: .public) \
                offset=\(chunk.startOffset, privacy: .public) \
                model=\(ctx.model, privacy: .public) \
                error=\(error.localizedDescription, privacy: .public)
                """
            )
            throw error
        }
        tracker.markCompleted(index)
        logger.debug(
            """
            chunk done offset=\(chunk.startOffset, privacy: .public) \
            segments=\(segs.count, privacy: .public)
            """
        )
        return shift(segs, by: chunk.startOffset)
    }

    // MARK: - API key resolution

    private static func requireAPIKey(for backend: TranscriptionBackend) throws -> String {
        if let key = KeychainHelper.getAPIKey(backend: backend.keychainKey), !key.isEmpty {
            return key
        }
        let env = ProcessInfo.processInfo.environment
        if let name = backend.envVar, let key = env[name], !key.isEmpty {
            return key
        }
        // Gemini accepts the generic Google AI key name as a secondary fallback.
        if backend == .gemini, let key = env["GOOGLE_API_KEY"], !key.isEmpty {
            return key
        }
        throw TranscriptionError.missingAPIKey(
            backend: backend.displayName,
            envVar: backend.envVar ?? ""
        )
    }

    private static func shift(
        _ segments: [CoreSegment],
        by offset: Double
    ) -> [CoreSegment] {
        segments.compactMap { seg in
            let trimmed = seg.text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            return CoreSegment(
                start: seg.start + offset,
                end: seg.end + offset,
                text: trimmed
            )
        }
    }

    private static func transcribeChunk(
        backend: TranscriptionBackend,
        chunkURL: URL,
        model: String,
        language: String?,
        apiKey: String
    ) async throws -> [CoreSegment] {
        switch backend {
        case .whisperkit:
            // The public `transcribe` entrypoint guards out `.whisperkit`
            // before reaching this function. A future caller that forgets
            // that guard should fail loudly rather than silently produce an
            // empty transcript.
            preconditionFailure("transcribeChunk called with .whisperkit backend")
        case .openai:
            return try await OpenAITranscription.call(
                audioURL: chunkURL, model: model, language: language, apiKey: apiKey
            )
        case .gemini:
            return try await GeminiTranscription.call(
                audioURL: chunkURL, model: model, language: language, apiKey: apiKey
            )
        }
    }
}

/// Aggregates per-chunk progress into a single smooth `(0..1)` fraction.
///
/// The old `ProgressCounter` only ticked when an API call returned, so the
/// bar sat frozen for a full chunk's wall-time then jumped by `1/total`.
/// For 10-min cloud chunks that's tens of seconds of "is it still working?"
/// uncertainty per step.
///
/// This tracker instead emits a continuous estimate at ~4 Hz:
///
///     progress = Σ chunk_fraction / total_chunks
///
/// where `chunk_fraction` is:
///   - 1.0           for completed chunks
///   - min(0.95, elapsed / expected_wall_time)   for in-flight chunks
///   - 0.0           for pending chunks
///
/// `expected_wall_time` is the running mean of wall-times of completed
/// chunks; until the first one finishes, we bootstrap with ~10× realtime
/// (e.g. 60 s for a 600 s audio chunk) so the bar moves immediately.
///
/// Lock-based rather than an actor so the per-chunk hooks can be called
/// synchronously from inside the task-group children without `await`.
/// Same `@unchecked Sendable` pattern as `ProgressSink` in
/// `TranscriptionService`.
///
/// `internal` access (instead of `private`) so unit tests can drive it
/// directly without round-tripping through `URLSession`.
final class CloudProgressTracker: @unchecked Sendable {
    /// Snapshot of the tracker's externally-visible state. Counts are
    /// included alongside the fraction so the UI can render "Transcribing
    /// 3 of 6 chunks" without re-deriving the counts from the float.
    struct Snapshot: Sendable, Equatable {
        let fraction: Double
        let completed: Int
        let inFlight: Int
        let total: Int
    }

    private enum State {
        case pending
        case inFlight(startedAt: Date)
        case done
    }

    private let lock = NSLock()
    private var states: [State]
    private var meanWallSeconds: Double
    private var completedCount: Int = 0
    private var lastEmittedFraction: Double = -1
    private let emit: (@Sendable (Snapshot) -> Void)?
    private var heartbeat: Task<Void, Never>?

    /// Cap on the in-flight estimate. Keeping a chunk under 1.0 until its
    /// API call actually returns avoids the bar hitting 100 % prematurely
    /// when our `meanWallSeconds` estimate is too optimistic.
    private static let inFlightCap: Double = 0.95

    /// Minimum change before a new value is forwarded. 0.5 percentage points
    /// is well below the smallest visible motion on a typical 200 px bar.
    private static let emitThreshold: Double = 0.005

    /// Heartbeat cadence. 4 Hz is fast enough that the bar feels alive
    /// without flooding the main actor.
    private static let heartbeatInterval: UInt64 = 250_000_000  // 250 ms

    /// Bootstrap real-time factor: 10× realtime is a reasonable guess for
    /// whisper-1 / gpt-4o-transcribe on a fast connection. It only matters
    /// until the first chunk completes, after which `meanWallSeconds` is
    /// driven by real measurements.
    private static let bootstrapRealtimeFactor: Double = 10

    init(
        total: Int,
        audioSecondsPerChunk: Double,
        emit: (@Sendable (Snapshot) -> Void)?
    ) {
        self.states = Array(repeating: .pending, count: total)
        self.meanWallSeconds = max(5, audioSecondsPerChunk / Self.bootstrapRealtimeFactor)
        self.emit = emit
    }

    /// Spawn the heartbeat. Idempotent — calling start twice replaces the
    /// previous task.
    func start() {
        heartbeat?.cancel()
        let interval = Self.heartbeatInterval
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                self?.tick()
            }
        }
    }

    /// Cancel the heartbeat and force-emit a final snapshot so the bar
    /// lands cleanly. Safe to call from `defer` because it's synchronous.
    func stop(finalFraction: Double = 1.0) {
        heartbeat?.cancel()
        heartbeat = nil
        let finalSnapshot = lock.withLock {
            let total = states.count
            return Snapshot(
                fraction: finalFraction,
                completed: total,
                inFlight: 0,
                total: total
            )
        }
        emitIfNeeded(finalSnapshot, force: true)
    }

    func markStarted(_ index: Int) {
        lock.withLock {
            guard states.indices.contains(index) else { return }
            states[index] = .inFlight(startedAt: Date())
        }
        // State edge: force emit so the UI sees `inFlight` count climb even
        // when the fraction barely moved (e.g. starting the 2nd of 6
        // chunks bumps fraction by ~0 but the count is meaningful).
        tick(force: true)
    }

    func markCompleted(_ index: Int) {
        lock.withLock {
            guard states.indices.contains(index) else { return }
            if case let .inFlight(start) = states[index] {
                let wall = Date().timeIntervalSince(start)
                completedCount += 1
                let n = Double(completedCount)
                meanWallSeconds = ((meanWallSeconds * (n - 1)) + wall) / n
            }
            states[index] = .done
        }
        // State edge: same rationale as markStarted.
        tick(force: true)
    }

    private func tick(force: Bool = false) {
        let snapshot = lock.withLock { computeSnapshotLocked() }
        emitIfNeeded(snapshot, force: force)
    }

    /// Caller must hold `lock`.
    private func computeSnapshotLocked() -> Snapshot {
        let total = states.count
        guard total > 0 else {
            return Snapshot(fraction: 0, completed: 0, inFlight: 0, total: 0)
        }
        let now = Date()
        var sum: Double = 0
        var completed = 0
        var inFlight = 0
        for state in states {
            switch state {
            case .pending:
                break
            case .done:
                sum += 1
                completed += 1
            case let .inFlight(start):
                let elapsed = now.timeIntervalSince(start)
                let expected = max(meanWallSeconds, 1)
                sum += min(Self.inFlightCap, elapsed / expected)
                inFlight += 1
            }
        }
        return Snapshot(
            fraction: sum / Double(total),
            completed: completed,
            inFlight: inFlight,
            total: total
        )
    }

    /// Emit if either:
    ///  - `force` is set (used by `stop` and start/complete edges so the
    ///    UI sees every state transition regardless of fraction motion), or
    ///  - the fraction moved by at least `emitThreshold` since last emit.
    private func emitIfNeeded(_ snapshot: Snapshot, force: Bool) {
        let shouldEmit = lock.withLock {
            let delta = abs(snapshot.fraction - lastEmittedFraction)
            let cross = force || lastEmittedFraction < 0 || delta >= Self.emitThreshold
            if cross { lastEmittedFraction = snapshot.fraction }
            return cross
        }
        if shouldEmit { emit?(snapshot) }
    }
}

// MARK: - OpenAI

/// `POST /v1/audio/transcriptions` with `verbose_json` + segment timestamps.
///
/// We deliberately stick to the documented multipart shape here rather than
/// pulling in a generated client — it's a single endpoint and the response
/// fields we care about (`segments[].start/end/text`) are stable.
enum OpenAITranscription {
    private static let endpoint = URL(
        string: "https://api.openai.com/v1/audio/transcriptions"
    )! // swiftlint:disable:this force_unwrapping

    static func call(
        audioURL: URL,
        model: String,
        language: String?,
        apiKey: String
    ) async throws -> [CoreSegment] {
        let boundary = "----transcribeer-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )

        var body = Data()
        body.appendField(boundary: boundary, name: "model", value: model)
        body.appendField(boundary: boundary, name: "response_format", value: "verbose_json")
        body.appendField(
            boundary: boundary,
            name: "timestamp_granularities[]",
            value: "segment"
        )
        if let language { body.appendField(boundary: boundary, name: "language", value: language) }
        try body.appendFile(
            boundary: boundary,
            name: "file",
            filename: audioURL.lastPathComponent,
            contentType: CloudTranscriptionService.uploadMimeType,
            fileURL: audioURL
        )
        body.append(Data("--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        try TranscriptionHTTP.checkOK(response: response, body: data, backend: "OpenAI")
        return try parseResponse(data)
    }

    struct Response: Decodable {
        let text: String?
        let duration: Double?
        let segments: [Segment]?

        struct Segment: Decodable {
            let start: Double
            let end: Double
            let text: String
        }
    }

    /// Internal so unit tests can exercise the response shape directly
    /// without round-tripping through URLSession.
    static func parseResponse(_ data: Data) throws -> [CoreSegment] {
        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw TranscriptionError.invalidResponse(
                backend: "OpenAI",
                detail: error.localizedDescription
            )
        }
        if let segs = decoded.segments, !segs.isEmpty {
            return segs.map { CoreSegment(start: $0.start, end: $0.end, text: $0.text) }
        }
        // Fall back to a single segment covering the whole chunk if the model
        // didn't return segment-level timestamps (some `gpt-4o-transcribe`
        // responses). Better than dropping the chunk silently.
        guard let text = decoded.text, !text.isEmpty else { return [] }
        let end = decoded.duration ?? 0
        return [CoreSegment(start: 0, end: end, text: text)]
    }
}

// MARK: - Gemini

/// Gemini `generateContent` with inline base64 audio + structured JSON output.
///
/// We constrain the model with `responseMimeType: "application/json"` and a
/// `responseSchema` describing an array of `{start, end, text}` segments, so
/// the response is parseable without prompt-engineering tricks. Inline audio
/// is fine here because we only ever send one 10-minute chunk at a time
/// (≤ 20 MB, the inline limit).
enum GeminiTranscription {
    static func call(
        audioURL: URL,
        model: String,
        language: String?,
        apiKey: String
    ) async throws -> [CoreSegment] {
        let endpoint = try buildEndpoint(model: model, apiKey: apiKey)
        let audio = try Data(contentsOf: audioURL)
        let payload = buildPayload(audioBase64: audio.base64EncodedString(), language: language)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        try TranscriptionHTTP.checkOK(response: response, body: data, backend: "Gemini")
        return try parseResponse(data)
    }

    private static func buildEndpoint(model: String, apiKey: String) throws -> URL {
        let path = "https://generativelanguage.googleapis.com/v1beta/models/" +
            "\(model):generateContent"
        guard var components = URLComponents(string: path) else {
            throw TranscriptionError.invalidResponse(
                backend: "Gemini", detail: "could not build endpoint URL"
            )
        }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else {
            throw TranscriptionError.invalidResponse(
                backend: "Gemini", detail: "could not finalise endpoint URL"
            )
        }
        return url
    }

    private static func buildPayload(
        audioBase64: String,
        language: String?
    ) -> [String: Any] {
        let langClause = language.map { "Audio language hint: \($0)." } ?? ""
        let prompt = """
            Transcribe this audio. Return a JSON array of segments. Each \
            segment must contain `start` (seconds, float), `end` (seconds, \
            float), and `text` (verbatim transcript with no speaker labels). \
            Keep segments short — break on natural pauses, ~3–8 seconds each. \
            Do not include any commentary, only the transcript. \(langClause)
            """
        let schema: [String: Any] = [
            "type": "ARRAY",
            "items": [
                "type": "OBJECT",
                "properties": [
                    "start": ["type": "NUMBER"],
                    "end": ["type": "NUMBER"],
                    "text": ["type": "STRING"],
                ],
                "required": ["start", "end", "text"],
            ],
        ]
        return [
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        ["text": prompt],
                        [
                            "inline_data": [
                                "mime_type": CloudTranscriptionService.uploadMimeType,
                                "data": audioBase64,
                            ],
                        ],
                    ],
                ],
            ],
            "generationConfig": [
                "temperature": 0,
                "responseMimeType": "application/json",
                "responseSchema": schema,
            ],
        ]
    }

    private struct Response: Decodable {
        let candidates: [Candidate]?

        struct Candidate: Decodable {
            let content: Content?
        }

        struct Content: Decodable {
            let parts: [Part]?
        }

        struct Part: Decodable {
            let text: String?
        }
    }

    private struct Segment: Decodable {
        let start: Double
        let end: Double
        let text: String
    }

    /// Internal so unit tests can exercise the response shape directly
    /// without round-tripping through URLSession.
    static func parseResponse(_ data: Data) throws -> [CoreSegment] {
        let envelope: Response
        do {
            envelope = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw TranscriptionError.invalidResponse(
                backend: "Gemini", detail: error.localizedDescription
            )
        }
        let text = envelope.candidates?.first?.content?.parts?
            .compactMap(\.text).joined() ?? ""
        guard !text.isEmpty, let payload = text.data(using: .utf8) else {
            throw TranscriptionError.invalidResponse(
                backend: "Gemini", detail: "empty response body"
            )
        }
        let segments: [Segment]
        do {
            segments = try JSONDecoder().decode([Segment].self, from: payload)
        } catch {
            throw TranscriptionError.invalidResponse(
                backend: "Gemini",
                detail: "could not decode segment JSON — \(error.localizedDescription)"
            )
        }
        return segments.map { CoreSegment(start: $0.start, end: $0.end, text: $0.text) }
    }
}

// MARK: - Shared HTTP error mapping

private enum TranscriptionHTTP {
    private static let logger = Logger(
        subsystem: "com.transcribeer", category: "CloudTranscription.HTTP"
    )

    static func checkOK(
        response: URLResponse,
        body: Data,
        backend: String
    ) throws {
        guard let http = response as? HTTPURLResponse else {
            logger.error(
                "\(backend, privacy: .public): no HTTPURLResponse from URLSession"
            )
            throw TranscriptionError.network(
                backend: backend, detail: "no HTTP response"
            )
        }
        guard !(200..<300).contains(http.statusCode) else { return }
        let text = String(data: body, encoding: .utf8) ?? "<binary>"
        let trimmed = text.count > 400 ? String(text.prefix(400)) + "…" : text
        logger.error(
            """
            \(backend, privacy: .public) HTTP \(http.statusCode, privacy: .public) \
            body=\(trimmed, privacy: .public)
            """
        )
        throw TranscriptionError.httpError(
            backend: backend,
            status: http.statusCode,
            body: trimmed
        )
    }
}

// MARK: - Multipart helpers

private extension Data {
    mutating func appendField(boundary: String, name: String, value: String) {
        append(Data("--\(boundary)\r\n".utf8))
        append(Data(
            "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8
        ))
        append(Data("\(value)\r\n".utf8))
    }

    mutating func appendFile(
        boundary: String,
        name: String,
        filename: String,
        contentType: String,
        fileURL: URL
    ) throws {
        let data = try Data(contentsOf: fileURL)
        append(Data("--\(boundary)\r\n".utf8))
        append(Data(
            "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8
        ))
        append(Data("Content-Type: \(contentType)\r\n\r\n".utf8))
        append(data)
        append(Data("\r\n".utf8))
    }
}
