import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("Folder classification policy", .serialized)
struct FolderClassificationCoordinatorTests {
    private let validReply = #"{"folder":"Rush","confidence":0.7}"#

    private func classifier(_ fixture: FolderClassificationFixture, spy: FolderClassificationSpyGenerator) -> FolderClassifier {
        FolderClassifier(databaseURL: fixture.store.resolvedDatabaseURL, generator: spy)
    }

    /// One earlier meeting of series `s1` filed into Rush by the user.
    private func seededFixture() throws -> (FolderClassificationFixture, rush: Int64) {
        let fixture = try FolderClassificationFixture()
        let rush = try fixture.store.createFolder(name: "Rush")
        let earlier = try fixture.meeting(series: "s1")
        try fixture.classification.moveMeeting(id: earlier, toFolder: rush)
        return (fixture, rush)
    }

    @Test("new settings default to suggesting and not auto-applying")
    func defaults() {
        let config = AppConfig()
        #expect(config.autoClassifyMeetings)
        #expect(config.autoApplyFolderSuggestions == false)
    }

    @Test("a decisive rule leaves a pending suggestion by default")
    func ruleSuggestsByDefault() async throws {
        let (fixture, rush) = try seededFixture()
        let id = try fixture.meeting(series: "s1")
        let spy = FolderClassificationSpyGenerator(reply: validReply)

        let outcome = await classifier(fixture, spy: spy).classify(meetingID: id, config: AppConfig())

        #expect(outcome == .suggested(.series))
        #expect(try fixture.store.meeting(id: id)?.folderID == nil)
        let row = try #require(try fixture.classification.pendingSuggestions().first)
        #expect(row.suggestion.folderID == rush)
        #expect(row.suggestion.reason == "Same recurring series as 1 meeting in Rush")
        #expect(await spy.requests.isEmpty)
    }

    @Test("auto-apply on files a decisive rule match")
    func autoApplyHonored() async throws {
        let (fixture, rush) = try seededFixture()
        let id = try fixture.meeting(series: "s1")
        var config = AppConfig()
        config.autoApplyFolderSuggestions = true

        let outcome = await classifier(fixture, spy: .init(reply: validReply)).classify(meetingID: id, config: config)

        #expect(outcome == .autoApplied(.series))
        #expect(try fixture.store.meeting(id: id)?.folderID == rush)
        #expect(try fixture.classification.pendingSuggestions().isEmpty)
    }

    @Test("a meeting that already has a folder is untouched")
    func folderedUntouched() async throws {
        let (fixture, _) = try seededFixture()
        let v12 = try fixture.store.createFolder(name: "V12")
        let id = try fixture.meeting(series: "s1")
        try fixture.store.moveMeeting(id: id, toFolder: v12)
        let spy = FolderClassificationSpyGenerator(reply: validReply)
        var config = AppConfig()
        config.autoApplyFolderSuggestions = true

        #expect(await classifier(fixture, spy: spy).classify(meetingID: id, config: config) == .ineligible)
        #expect(try fixture.store.meeting(id: id)?.folderID == v12)
        #expect(try fixture.classification.suggestions(meetingID: id).isEmpty)
        #expect(await spy.requests.isEmpty)
    }

    @Test("a meeting that is still recording is untouched")
    func recordingUntouched() async throws {
        let (fixture, _) = try seededFixture()
        let id = try fixture.meeting(series: "s1", status: .recording)
        let spy = FolderClassificationSpyGenerator(reply: validReply)
        #expect(await classifier(fixture, spy: spy).classify(meetingID: id, config: AppConfig()) == .ineligible)
        #expect(try fixture.classification.suggestions(meetingID: id).isEmpty)
        #expect(await spy.requests.isEmpty)
    }

    @Test("when rules abstain the LLM suggestion is stored as pending, never applied")
    func llmFallbackNeverApplies() async throws {
        let fixture = try FolderClassificationFixture()
        let rush = try fixture.store.createFolder(name: "Rush")
        let id = try fixture.meeting(title: "Something new")
        let spy = FolderClassificationSpyGenerator(reply: validReply)
        var config = AppConfig()
        config.autoApplyFolderSuggestions = true

        let outcome = await classifier(fixture, spy: spy).classify(meetingID: id, config: config)

        #expect(outcome == .suggested(.llm))
        #expect(await spy.requests.count == 1)
        #expect(try fixture.store.meeting(id: id)?.folderID == nil)
        #expect(try fixture.classification.pendingSuggestions().first?.suggestion.folderID == rush)
    }

    @Test("an LLM reply that names no valid folder leaves no suggestion", arguments: [
        "nonsense", #"{"folder":null,"confidence":0.1}"#, #"{"folder":"Nope","confidence":0.9}"#,
    ])
    func llmInvalidLeavesNothing(reply: String) async throws {
        let fixture = try FolderClassificationFixture()
        _ = try fixture.store.createFolder(name: "Rush")
        let id = try fixture.meeting(title: "Something new")
        let outcome = await classifier(fixture, spy: .init(reply: reply)).classify(meetingID: id, config: AppConfig())
        #expect(outcome == .noSuggestion)
        #expect(try fixture.classification.suggestions(meetingID: id).isEmpty)
    }

    @Test("a private meeting on an untrusted backend makes no LLM call and leaves no suggestion")
    func privateUntrustedNoCall() async throws {
        let fixture = try FolderClassificationFixture()
        _ = try fixture.store.createFolder(name: "Rush")
        let id = try fixture.meeting(title: "Something new")
        try fixture.store.setMeetingPrivate(id: id, isPrivate: true)
        let spy = FolderClassificationSpyGenerator(reply: validReply)
        var config = AppConfig()
        config.privateTrustedBackends = []

        #expect(await classifier(fixture, spy: spy).classify(meetingID: id, config: config) == .noSuggestion)
        #expect(await spy.requests.isEmpty)
        #expect(try fixture.classification.suggestions(meetingID: id).isEmpty)
    }

    @Test("a private meeting on a trusted backend is sent")
    func privateTrustedCalls() async throws {
        let fixture = try FolderClassificationFixture()
        _ = try fixture.store.createFolder(name: "Rush")
        let id = try fixture.meeting(title: "Something new")
        try fixture.store.setMeetingPrivate(id: id, isPrivate: true)
        let spy = FolderClassificationSpyGenerator(reply: validReply)
        var config = AppConfig()
        config.privateTrustedBackends = [PrivateMeetingPolicy.effectiveBackend(of: config)]

        #expect(await classifier(fixture, spy: spy).classify(meetingID: id, config: config) == .suggested(.llm))
        #expect(await spy.requests.count == 1)
    }

    @Test("the LLM is asked once per meeting")
    func llmAskedOnce() async throws {
        let fixture = try FolderClassificationFixture()
        _ = try fixture.store.createFolder(name: "Rush")
        let id = try fixture.meeting(title: "Something new")
        let spy = FolderClassificationSpyGenerator(reply: validReply)
        let classifier = classifier(fixture, spy: spy)
        _ = await classifier.classify(meetingID: id, config: AppConfig())
        _ = await classifier.classify(meetingID: id, config: AppConfig())
        #expect(await spy.requests.count == 1)
    }

    // MARK: - Batch runner

    @MainActor
    @Test("the batch classifies every unfiled meeting")
    func batchClassifiesUnfiled() async throws {
        let (fixture, _) = try seededFixture()
        let ids = try (0..<3).map { _ in try fixture.meeting(series: "s1") }
        let runner = FolderClassificationRunner(classifier: classifier(fixture, spy: .init(reply: validReply)), batchSize: 2)

        let processed = await runner.classifyUnfiled(config: AppConfig(), isRecording: { false })

        #expect(processed == 3)
        for id in ids {
            #expect(try fixture.classification.suggestions(meetingID: id).map(\.state) == [.pending])
        }
    }

    @MainActor
    @Test("nothing is classified while a meeting is recording")
    func batchSkipsWhileRecording() async throws {
        let (fixture, _) = try seededFixture()
        let id = try fixture.meeting(series: "s1")
        let spy = FolderClassificationSpyGenerator(reply: validReply)
        let runner = FolderClassificationRunner(classifier: classifier(fixture, spy: spy), batchSize: 2)

        #expect(await runner.classifyUnfiled(config: AppConfig(), isRecording: { true }) == 0)
        #expect(await runner.classifyCompleted(meetingID: id, config: AppConfig(), isRecording: { true }) == nil)
        #expect(try fixture.classification.suggestions(meetingID: id).isEmpty)
        #expect(await spy.requests.isEmpty)
    }

    @MainActor
    @Test("the completion trigger respects the auto-classify setting")
    func completionRespectsSetting() async throws {
        let (fixture, _) = try seededFixture()
        let id = try fixture.meeting(series: "s1")
        let runner = FolderClassificationRunner(classifier: classifier(fixture, spy: .init(reply: validReply)))
        var config = AppConfig()
        config.autoClassifyMeetings = false
        #expect(await runner.classifyCompleted(meetingID: id, config: config, isRecording: { false }) == nil)
        config.autoClassifyMeetings = true
        #expect(await runner.classifyCompleted(meetingID: id, config: config, isRecording: { false }) == .suggested(.series))
    }

    @MainActor
    @Test("a meeting finished during another recording waits until recording stops")
    func queuedUntilRecordingStops() async throws {
        let (fixture, _) = try seededFixture()
        let id = try fixture.meeting(series: "s1")
        let runner = FolderClassificationRunner(classifier: classifier(fixture, spy: .init(reply: validReply)))
        var changes = 0
        runner.onChange = { changes += 1 }

        #expect(runner.enqueueCompleted(meetingID: id, config: AppConfig(), isRecording: { true }) == nil)
        #expect(try fixture.classification.suggestions(meetingID: id).isEmpty)

        await runner.drainQueue(config: AppConfig(), isRecording: { false })?.value
        #expect(try fixture.classification.suggestions(meetingID: id).map(\.state) == [.pending])
        #expect(changes == 1)
        #expect(runner.drainQueue(config: AppConfig(), isRecording: { false }) == nil)
    }

    @MainActor
    @Test("a cancelled batch stops")
    func batchCancels() async throws {
        let (fixture, _) = try seededFixture()
        for _ in 0..<4 { try fixture.meeting(series: "s1") }
        let runner = FolderClassificationRunner(classifier: classifier(fixture, spy: .init(reply: validReply)), batchSize: 1)
        let task = Task { @MainActor in await runner.classifyUnfiled(config: AppConfig(), isRecording: { false }) }
        task.cancel()
        #expect(await task.value < 4)
    }
}
