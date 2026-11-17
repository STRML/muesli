import ArgumentParser
import FluidAudio
import Foundation
import MuesliNativeApp

struct DiarizeJSONPayload: Encodable {
    let segments: [NativeFileDiarizer.Segment]
    let speakerCount: Int

    init(segments: [NativeFileDiarizer.Segment]) {
        self.segments = segments
        speakerCount = Set(segments.map(\.speaker)).count
    }
}

struct DiarizeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diarize",
        abstract: "Label who spoke when in a local audio file with muesli's post-meeting speaker diarizer."
    )

    @OptionGroup var global: GlobalOptions
    @Argument(help: "Audio file to diarize. Supported extensions: mp3, mp4, m4a, wav.")
    var file: String
    @Option(name: .long, help: "Write command output to a file instead of stdout.")
    var output: String?

    mutating func validate() throws {
        guard MuesliAudioFilePreparer.isSupportedFileURL(URL(fileURLWithPath: file)) else {
            throw ValidationError("Unsupported audio file extension. Supported extensions: mp3, mp4, m4a, wav.")
        }
    }

    func run() async throws {
        let context = CLIContext(options: global)
        let sourceURL = URL(fileURLWithPath: file).standardizedFileURL
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw CLIError.notFound("Audio file does not exist: \(sourceURL.path)", fix: "Pass a local .mp3, .mp4, .m4a, or .wav file path.")
        }

        let prepared = try await MuesliAudioFilePreparer().prepareAudio(sourceURL: sourceURL)
        defer {
            if prepared.deleteWhenDone { try? FileManager.default.removeItem(at: prepared.wavURL) }
        }
        let segments: [NativeFileDiarizer.Segment]
        do {
            segments = try await NativeFileDiarizer.diarize(wavURL: prepared.wavURL, progress: { fputs("[muesli-cli] \($0)\n", stderr) })
        } catch DiarizerError.notInitialized {
            throw CLIError.notFound(
                "Speaker diarization models could not be loaded.",
                fix: "The load failed or ran past 5 minutes; stderr shows the load error if there was one. The first run downloads the models, so check the network and retry."
            )
        }

        let envelope = SuccessEnvelope(
            command: "muesli-cli diarize",
            data: DiarizeJSONPayload(segments: segments),
            meta: MetaBody(schemaVersion: 1, generatedAt: timestampString(), dbPath: context.databaseURL.path, warnings: [])
        )
        let text = String(decoding: try encodedJSON(envelope), as: UTF8.self)
        if let output {
            try writeOutput(text, to: URL(fileURLWithPath: output))
        } else {
            FileHandle.standardOutput.write(Data(text.utf8))
        }
    }
}
