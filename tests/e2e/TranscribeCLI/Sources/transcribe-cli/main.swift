import Foundation
import WhisperKit

// Usage: transcribe-cli <audio.wav> [--language he] [--model openai_whisper-large-v3_turbo]
//
// Writes the plain transcript to stdout. Progress/info go to stderr so callers
// can capture a clean transcript via shell redirection.

struct Args {
    var audio: URL
    var language: String?
    var model: String
}

func parseArgs() -> Args {
    let argv = CommandLine.arguments
    guard argv.count >= 2 else {
        fputs("Usage: transcribe-cli <audio> [--language he] [--model openai_whisper-large-v3_turbo]\n", stderr)
        exit(2)
    }
    var language: String?
    var model = "openai_whisper-large-v3_turbo"
    var positional: String?
    var i = 1
    while i < argv.count {
        let a = argv[i]
        switch a {
        case "--language":
            i += 1
            guard i < argv.count else { fputs("--language requires value\n", stderr); exit(2) }
            let v = argv[i]
            language = (v == "auto") ? nil : v
        case "--model":
            i += 1
            guard i < argv.count else { fputs("--model requires value\n", stderr); exit(2) }
            model = argv[i]
        default:
            positional = a
        }
        i += 1
    }
    guard let path = positional else {
        fputs("Missing audio path\n", stderr); exit(2)
    }
    return Args(audio: URL(fileURLWithPath: path), language: language, model: model)
}

let args = parseArgs()

let home = FileManager.default.homeDirectoryForCurrentUser
let modelsDir = home.appendingPathComponent(".transcribeer/models", isDirectory: true)
try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

fputs("[transcribe-cli] model=\(args.model) language=\(args.language ?? "auto")\n", stderr)
fputs("[transcribe-cli] models_dir=\(modelsDir.path)\n", stderr)
fputs("[transcribe-cli] audio=\(args.audio.path)\n", stderr)

let config = WhisperKitConfig(
    model: args.model,
    downloadBase: modelsDir,
    verbose: false,
    logLevel: .none,
    prewarm: true,
    load: true,
    download: true
)

let started = Date()
let kit = try await WhisperKit(config)
fputs("[transcribe-cli] model loaded in \(Int(-started.timeIntervalSinceNow))s\n", stderr)

let decodeOptions = DecodingOptions(
    verbose: false,
    language: args.language,
    chunkingStrategy: .vad
)

let transcribeStart = Date()
let results = try await kit.transcribe(audioPath: args.audio.path, decodeOptions: decodeOptions)
fputs("[transcribe-cli] transcribed in \(Int(-transcribeStart.timeIntervalSinceNow))s\n", stderr)

// WhisperKit segments carry the raw decoder stream including special tokens
// like <|startoftranscript|>, <|he|>, <|transcribe|>, <|0.00|>. Strip anything
// inside <|...|> so the hypothesis is plain text suitable for comparison.
let specialToken = try NSRegularExpression(pattern: "<\\|[^|]*\\|>")
func clean(_ s: String) -> String {
    let range = NSRange(s.startIndex..., in: s)
    let stripped = specialToken.stringByReplacingMatches(
        in: s, range: range, withTemplate: " "
    )
    return stripped
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}

let text = results
    .flatMap { $0.segments }
    .map { clean($0.text) }
    .filter { !$0.isEmpty }
    .joined(separator: " ")

print(text)
