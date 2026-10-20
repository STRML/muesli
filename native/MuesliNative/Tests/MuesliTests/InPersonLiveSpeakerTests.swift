import AVFoundation
import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

/// Live "Speaker N" labels for in-person meetings (mic only). Each test maps to a
/// row of the failure matrix in the PR description.
@Suite("In-person live speaker labels", .serialized)
struct InPersonLiveSpeakerTests {
    private func segments() -> [SpeechSegment] {
        [SpeechSegment(start: 0, end: 2, text: "a"), SpeechSegment(start: 3, end: 5, text: "b"),
         SpeechSegment(start: 6, end: 8, text: "c")]
    }

    private func runningSession(
        seconds: Double = 10,
        _ activeSlot: @escaping @Sendable (Int) -> Int?
    ) async -> LiveSpeakerLabelSession {
        let engine = ScriptedLiveSpeakerEngine(activeSlot: activeSlot)
        let session = LiveSpeakerLabelSession(factory: { engine })
        session.start()
        _ = await liveSpeakerWaitUntil { session.status == .running }
        feedLiveSpeakerAudio(session, seconds: seconds)
        return session
    }

    private func meeting(config: AppConfig = AppConfig(), inPerson: Bool = true, useQueue: Bool = false) -> (MeetingSession, ContractProducer) {
        let producer = ContractProducer(useQueue: useQueue)
        let route = RouteAwareMeetingMicRecorder(systemDefaultRecorder:
            StreamingMeetingMicRecorderAdapter(recorder: producer, kind: .systemDefaultStreaming))
        let session = MeetingSession(title: "in-person live", calendarEventID: nil,
            backend: .parakeetEnglish,
            runtime: RuntimePaths(repoRoot: URL(fileURLWithPath: NSTemporaryDirectory()),
                                  menuIcon: nil, appIcon: nil, bundlePath: nil),
            config: config,
            templateSnapshot: .init(id: "test", name: "test", kind: .custom, prompt: ""),
            transcriptionCoordinator: TranscriptionCoordinator(), meetingMicRecorder: route,
            systemAudioCapture: inPerson ? nil : ContractSystemAudio(),
            aec: MeetingNeuralAec(preloadedProcessor: ContractAecProcessor()), inPerson: inPerson)
        return (session, producer)
    }

    private func micValues(_ count: Int) -> [Int] { Array(repeating: 8, count: count) }

    private func retainedSampleCount(_ urls: (URL?, URL?, URL?)) throws -> Int {
        defer { for url in [urls.0, urls.1, urls.2].compactMap({ $0 }) { try? FileManager.default.removeItem(at: url) } }
        return (try Data(contentsOf: try #require(urls.2)).count - 44) / 2
    }

    // MARK: Which meetings get a session

    // Row: model missing.
    @Test("in-person with the model missing starts no session, so nothing waits on a load that cannot work",
          arguments: [false, true])
    func modelMissing(setting: Bool) {
        let factory: LiveSpeakerLabelSession.EngineFactory = { throw LiveSpeakerModelStore.StoreError.notDownloaded }
        var config = AppConfig()
        config.enableLiveSpeakerLabels = setting
        #expect(MeetingSession.makeLiveSpeakerSession(
            config: config, inPerson: true, modelAvailable: false, factory: factory) == nil)
    }

    // Row: in-person defaults to live labels.
    @Test("in-person with the model cached labels live even when the setting is off")
    func inPersonDefaultsOn() {
        let factory: LiveSpeakerLabelSession.EngineFactory = { throw LiveSpeakerModelStore.StoreError.notDownloaded }
        #expect(AppConfig().enableLiveSpeakerLabels == false)
        #expect(MeetingSession.makeLiveSpeakerSession(
            config: AppConfig(), inPerson: true, modelAvailable: true, factory: factory) != nil)
    }

    // Rows: normal meeting unchanged / setting off in a normal meeting.
    @Test("normal meetings still follow the setting alone, whether or not the model is cached",
          arguments: [true, false])
    func normalMeetingGate(modelAvailable: Bool) {
        let factory: LiveSpeakerLabelSession.EngineFactory = { throw LiveSpeakerModelStore.StoreError.notDownloaded }
        var config = AppConfig()
        #expect(MeetingSession.makeLiveSpeakerSession(
            config: config, inPerson: false, modelAvailable: modelAvailable, factory: factory) == nil)
        config.enableLiveSpeakerLabels = true
        #expect(MeetingSession.makeLiveSpeakerSession(
            config: config, inPerson: false, modelAvailable: modelAvailable, factory: factory) != nil)
    }

    // MARK: Labels

    // Row: several voices.
    @Test("two voices on the mic show as Speaker 1 and Speaker 2")
    func twoVoices() async {
        let session = await runningSession { $0 < 25 ? 0 : 2 }
        let labels = await MeetingSession.liveMicDisplaySpeakers(for: segments(), using: session)
        #expect(labels == ["Speaker 1", "Speaker 2", "Speaker 2"])
    }

    // Row: one speaker.
    @Test("a one-speaker room is Speaker 1 throughout")
    func oneVoice() async {
        let session = await runningSession { _ in 3 }
        let labels = await MeetingSession.liveMicDisplaySpeakers(for: segments(), using: session)
        #expect(labels == ["Speaker 1", "Speaker 1", "Speaker 1"])
    }

    // Row: a range the diarizer heard nobody in.
    @Test("a range with no detected voice is the undiarized Speaker 1, never Others")
    func silentRange() async {
        let session = await runningSession { _ in nil }
        let labels = await MeetingSession.liveMicDisplaySpeakers(for: segments(), using: session)
        #expect(labels == Array(repeating: InPersonMeeting.undiarizedSpeaker, count: 3))
    }

    // Row: no session at all (model missing).
    @Test("no session means no display labels, so the Live tab keeps today's labels")
    func noSession() async {
        #expect(await MeetingSession.liveMicDisplaySpeakers(for: segments(), using: nil) == nil)
    }

    // Row: model load fails.
    @Test("a failed load falls back to today's labels instead of Others")
    func loadFailed() async {
        let session = LiveSpeakerLabelSession(factory: { throw LiveSpeakerModelStore.StoreError.notDownloaded })
        session.start()
        #expect(await liveSpeakerWaitUntil { session.status == .failed(.loadFailed) })
        #expect(await MeetingSession.liveMicDisplaySpeakers(for: segments(), using: session) == nil)
    }

    // Row: model still loading when a chunk commits.
    @Test("a chunk committed while the model loads keeps today's label")
    func stillLoading() async {
        let session = LiveSpeakerLabelSession(factory: {
            try await Task.sleep(for: .seconds(120))
            throw CancellationError()
        })
        session.start()
        feedLiveSpeakerAudio(session, seconds: 2)
        #expect(session.status == .loading)
        #expect(await MeetingSession.liveMicDisplaySpeakers(for: segments(), using: session) == nil)
        session.stop()
    }

    // Row: engine fails mid-meeting.
    @Test("an engine error mid-meeting stops live labels; later chunks fall back")
    func engineFailsMidMeeting() async {
        let engine = ScriptedLiveSpeakerEngine(failAtSamples: 120_000) { _ in 0 }
        let session = LiveSpeakerLabelSession(factory: { engine })
        session.start()
        _ = await liveSpeakerWaitUntil { session.status == .running }
        feedLiveSpeakerAudio(session, seconds: 10)
        #expect(await liveSpeakerWaitUntil { session.status == .failed(.engineError) })
        #expect(await MeetingSession.liveMicDisplaySpeakers(for: segments(), using: session) == nil)
    }

    // Row: stop while chunks are still committing.
    @Test("labels already computed survive Stop, so chunks still committing are labelled")
    func labelsSurviveStop() async {
        let session = await runningSession { $0 < 25 ? 0 : 2 }
        session.stop()
        #expect(await liveSpeakerWaitUntil { session.status == .stopped })
        let labels = await MeetingSession.liveMicDisplaySpeakers(for: segments(), using: session)
        #expect(labels == ["Speaker 1", "Speaker 2", "Speaker 2"])
    }

    @Test("a session stopped before its model loaded answers with today's labels")
    func stopBeforeLoad() async {
        let session = LiveSpeakerLabelSession(factory: {
            try await Task.sleep(for: .seconds(120))
            throw CancellationError()
        })
        session.start()
        session.stop()
        #expect(await MeetingSession.liveMicDisplaySpeakers(for: segments(), using: session) == nil)
    }

    // MARK: Sample feed

    // Row: in-person feeds the mic stream, the same stream the chunk timing counts.
    @Test("in-person mic samples reach the live session sample for sample")
    func inPersonFeedsMic() async throws {
        let (session, producer) = meeting()
        let engine = ScriptedLiveSpeakerEngine { _ in 0 }
        let live = LiveSpeakerLabelSession(factory: { engine })
        live.start()
        session.testingInstallLiveSpeakerSession(live)
        try await session.testingStartCapture()
        let start = MicrophoneCaptureAudio.frame(atHostTime: mach_absolute_time()) - 4096
        for index in 0..<5 { try producer.emit(micValues(1_600), at: start + Int64(index * 1_600)) }
        #expect(await liveSpeakerWaitUntil { engine.totalSamplesSeen == 8_000 })
        #expect(try retainedSampleCount(await session.testingFinishCapture()) == 8_000)
    }

    // Row: normal meeting unchanged.
    @Test("a normal meeting never feeds the microphone to the live session")
    func normalMeetingDoesNotFeedMic() async throws {
        var config = AppConfig()
        config.enableLiveSpeakerLabels = true
        let (session, producer) = meeting(config: config, inPerson: false)
        let engine = ScriptedLiveSpeakerEngine { _ in 0 }
        let live = LiveSpeakerLabelSession(factory: { engine })
        live.start()
        session.testingInstallLiveSpeakerSession(live)
        try await session.testingStartCapture()
        let start = MicrophoneCaptureAudio.frame(atHostTime: mach_absolute_time()) - 4096
        for index in 0..<5 { try producer.emit(micValues(1_600), at: start + Int64(index * 1_600)) }
        #expect(try retainedSampleCount(await session.testingFinishCapture()) > 0)
        try await Task.sleep(for: .milliseconds(200))
        #expect(engine.totalSamplesSeen == 0)
    }

    // Row: pause/resume mid-meeting.
    @Test("pause and resume add no gap and no duplicate: the live clock equals the recorded mic")
    func pauseResume() async throws {
        let (session, producer) = meeting()
        let engine = ScriptedLiveSpeakerEngine { _ in 0 }
        let live = LiveSpeakerLabelSession(factory: { engine })
        live.start()
        session.testingInstallLiveSpeakerSession(live)
        let resumed = DispatchSemaphore(value: 0)
        producer.afterResume = { resumed.signal() }
        session.testingConsumeChunk = { _, url, _ in try? FileManager.default.removeItem(at: url) }
        try await session.testingStartCapture()
        let start = MicrophoneCaptureAudio.frame(atHostTime: mach_absolute_time()) - 4096
        try producer.emit(micValues(3_200), at: start)
        await MainActor.run { session.pause() }
        await MainActor.run { session.resume() }
        let didResume = try await MeetingCaptureLifecycle.onDriverQueue { resumed.wait(timeout: .now() + 5) }
        #expect(didResume == .success)
        let later = MicrophoneCaptureAudio.frame(atHostTime: mach_absolute_time()) + 1_000
        try producer.emit(micValues(3_200), at: later)
        #expect(await liveSpeakerWaitUntil { engine.totalSamplesSeen == 6_400 })
        #expect(try retainedSampleCount(await session.testingFinishCapture()) == 6_400)
    }
}
