import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("LiveSpeakerLabelSession")
struct LiveSpeakerLabelSessionTests {
    private typealias Session = LiveSpeakerLabelSession

    private func session(
        limits: Session.Limits = Session.Limits(),
        factory: @escaping Session.EngineFactory
    ) -> Session {
        let session = Session(factory: factory, limits: limits)
        session.start()
        return session
    }

    private func twoSpeakerEngine() -> ScriptedLiveSpeakerEngine {
        ScriptedLiveSpeakerEngine { frame in frame < 100 ? 1 : 3 }
    }

    @Test("labels system audio by first appearance and keeps one clock across buffers")
    func labelsRunningMeeting() async {
        let engine = twoSpeakerEngine()
        let sut = session { engine }
        #expect(await liveSpeakerWaitUntil { sut.status == .running })
        feedLiveSpeakerAudio(sut, seconds: 20)

        #expect(await sut.label(start: 1, end: 3) == "Speaker 1")
        #expect(await sut.label(start: 12, end: 14) == "Speaker 2")
        #expect(sut.status == .running)
    }

    @Test("a model that is not downloaded falls back to Others without waiting")
    func modelMissing() async {
        var limits = Session.Limits()
        limits.coverageWait = .seconds(5)
        let sut = session(limits: limits) { throw LiveSpeakerModelStore.StoreError.notDownloaded }
        #expect(await liveSpeakerWaitUntil { sut.status == .failed(.loadFailed) })

        feedLiveSpeakerAudio(sut, seconds: 5)
        let started = ContinuousClock.now
        #expect(await sut.label(start: 1, end: 3) == "Others")
        #expect(ContinuousClock.now - started < .seconds(1))
    }

    @Test("a load that throws falls back to Others and recording audio calls stay safe")
    func loadFailure() async {
        struct Boom: Error {}
        let sut = session { throw Boom() }
        feedLiveSpeakerAudio(sut, seconds: 3)
        #expect(await liveSpeakerWaitUntil { sut.status == .failed(.loadFailed) })
        sut.enqueue([0.1, 0.2])
        #expect(await sut.label(start: 0, end: 1) == "Others")
    }

    @Test("a load that outlives the timeout is abandoned and the late engine never gets audio")
    func loadTimeout() async {
        var limits = Session.Limits()
        limits.loadTimeout = .milliseconds(100)
        let late = twoSpeakerEngine()
        let sut = session(limits: limits) {
            try? await Task.sleep(for: .milliseconds(400))
            return late
        }
        #expect(await liveSpeakerWaitUntil { sut.status == .failed(.loadTimedOut) })

        try? await Task.sleep(for: .milliseconds(500))
        feedLiveSpeakerAudio(sut, seconds: 5)
        #expect(sut.status == .failed(.loadTimedOut))
        #expect(late.totalSamplesSeen == 0)
        #expect(await sut.label(start: 1, end: 3) == "Others")
    }

    @Test("an engine error stops labeling but keeps labels for audio it already covered")
    func engineError() async {
        let engine = ScriptedLiveSpeakerEngine(failAtSamples: 40_000) { _ in 2 }
        let sut = session { engine }
        #expect(await liveSpeakerWaitUntil { sut.status == .running })
        feedLiveSpeakerAudio(sut, seconds: 2)
        #expect(await liveSpeakerWaitUntil { engine.totalSamplesSeen == 32_000 })

        feedLiveSpeakerAudio(sut, seconds: 3)
        #expect(await liveSpeakerWaitUntil { sut.status == .failed(.engineError) })
        #expect(await sut.label(start: 0.5, end: 1.5) == "Speaker 1")
        #expect(await sut.label(start: 4, end: 5) == "Others")
    }

    @Test("a backlog that grows past the limit while running shuts the labeler down")
    func backlogOverflowWhileRunning() async {
        var limits = Session.Limits()
        limits.maxBacklogSeconds = 2
        let gate = DispatchSemaphore(value: 0)
        let engine = ScriptedLiveSpeakerEngine(gate: gate) { _ in 0 }
        let sut = session(limits: limits) { engine }
        #expect(await liveSpeakerWaitUntil { sut.status == .running })

        feedLiveSpeakerAudio(sut, seconds: 10)
        #expect(sut.status == .failed(.backlogOverflow))
        #expect(await sut.label(start: 0, end: 1) == "Others")
        gate.signal()
        gate.signal()
    }

    @Test("audio that piles up while the model loads drops the oldest and shifts the clock")
    func backlogWhileLoading() async {
        var limits = Session.Limits()
        limits.maxBacklogSeconds = 4
        let release = AsyncStream<Void>.makeStream()
        let engine = ScriptedLiveSpeakerEngine(lagFrames: 0) { frame in frame < 40 ? 2 : nil }
        let sut = session(limits: limits) {
            for await _ in release.stream { break }
            return engine
        }

        feedLiveSpeakerAudio(sut, seconds: 10)
        #expect(sut.status == .loading)
        release.continuation.yield()
        #expect(await liveSpeakerWaitUntil { sut.status == .running })

        #expect(await sut.label(start: 7, end: 9) == "Speaker 1")
        #expect(await sut.label(start: 0, end: 5) == "Others")
    }

    @Test("while the model is still loading, lines are labeled Others at once instead of waiting")
    func labelWhileLoadingDoesNotWait() async {
        var limits = Session.Limits()
        limits.coverageWait = .seconds(5)
        let release = AsyncStream<Void>.makeStream()
        let sut = session(limits: limits) {
            for await _ in release.stream { break }
            return ScriptedLiveSpeakerEngine { _ in 0 }
        }
        feedLiveSpeakerAudio(sut, seconds: 2)

        let started = ContinuousClock.now
        #expect(await sut.label(start: 0, end: 1) == "Others")
        #expect(ContinuousClock.now - started < .seconds(1))
        release.continuation.yield()
    }

    @Test("a label request past the covered audio waits a bounded time, then answers Others")
    func coverageWaitIsBounded() async {
        var limits = Session.Limits()
        limits.coverageWait = .milliseconds(200)
        let engine = ScriptedLiveSpeakerEngine { _ in 0 }
        let sut = session(limits: limits) { engine }
        #expect(await liveSpeakerWaitUntil { sut.status == .running })
        feedLiveSpeakerAudio(sut, seconds: 1)

        let started = ContinuousClock.now
        #expect(await sut.label(start: 5, end: 6) == "Others")
        let elapsed = ContinuousClock.now - started
        #expect(elapsed >= .milliseconds(150))
        #expect(elapsed < .seconds(2))
    }

    @Test("stop flushes the last partial window so late commits still get a label")
    func stopFlushesTail() async {
        let engine = ScriptedLiveSpeakerEngine(lagFrames: 5) { _ in 1 }
        let sut = session { engine }
        #expect(await liveSpeakerWaitUntil { sut.status == .running })
        feedLiveSpeakerAudio(sut, seconds: 10)
        #expect(await liveSpeakerWaitUntil { engine.totalSamplesSeen == 160_000 })

        sut.stop()
        #expect(await liveSpeakerWaitUntil { sut.status == .stopped })
        #expect(engine.finishCalls == 1)
        #expect(await sut.label(start: 9.6, end: 10.0) == "Speaker 1")
    }

    @Test("odd-sized system buffers reach the engine as whole 100 ms blocks; stop flushes the remainder")
    func engineOnlySeesWholeBlocks() async {
        let engine = ScriptedLiveSpeakerEngine { _ in 1 }
        let sut = session { engine }
        #expect(await liveSpeakerWaitUntil { sut.status == .running })

        let odd = [Float](repeating: 0.1, count: 1_601)
        for _ in 0..<1_000 { sut.enqueue(odd) }
        let whole = (1_000 * 1_601) / 1_600 * 1_600
        #expect(await liveSpeakerWaitUntil { engine.totalSamplesSeen == whole })
        #expect(engine.calledWithPartialBlock == 0)

        sut.stop()
        #expect(await liveSpeakerWaitUntil { sut.status == .stopped })
        #expect(engine.totalSamplesSeen == 1_000 * 1_601)
    }

    @Test("stop is idempotent and later audio is ignored")
    func stopTwice() async {
        let engine = twoSpeakerEngine()
        let sut = session { engine }
        #expect(await liveSpeakerWaitUntil { sut.status == .running })
        feedLiveSpeakerAudio(sut, seconds: 5)
        sut.stop()
        sut.stop()
        #expect(await liveSpeakerWaitUntil { sut.status == .stopped })

        let seen = engine.totalSamplesSeen
        feedLiveSpeakerAudio(sut, seconds: 5)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(engine.totalSamplesSeen == seen)
        #expect(engine.finishCalls == 1)
    }

    @Test("stopping while the model is still loading discards the late engine")
    func stopDuringLoad() async {
        let release = AsyncStream<Void>.makeStream()
        let engine = twoSpeakerEngine()
        let sut = session {
            for await _ in release.stream { break }
            return engine
        }
        feedLiveSpeakerAudio(sut, seconds: 2)
        sut.stop()
        release.continuation.yield()
        try? await Task.sleep(for: .milliseconds(200))

        #expect(sut.status == .stopped)
        #expect(engine.totalSamplesSeen == 0)
        #expect(await sut.label(start: 0, end: 1) == "Others")
    }
}
