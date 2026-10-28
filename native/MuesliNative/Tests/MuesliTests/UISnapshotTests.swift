import AppKit
import Foundation
import SwiftUI
import Testing
import MuesliCore
@testable import MuesliNativeApp

/// Renders the private-meetings, folder-suggestion and settings screens to PNG files so they can
/// be reviewed without launching the app or granting screen-capture rights.
/// Opt in with `MUESLI_UI_SNAPSHOT_DIR=/some/dir swift test --filter UISnapshotTests`.
@MainActor
@Suite("UI snapshots (opt-in)", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["MUESLI_UI_SNAPSHOT_DIR"] != nil))
struct UISnapshotTests {
    private let outputDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MUESLI_UI_SNAPSHOT_DIR"] ?? NSTemporaryDirectory(), isDirectory: true)

    private func render<V: View>(_ view: V, width: CGFloat, height: CGFloat, name: String) throws {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let framed = view
            .frame(width: width, height: height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)
        // A hosting view inside a real (never shown) window, so scroll views and lists draw their content.
        let hosting = NSHostingView(rootView: framed)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        for _ in 0..<6 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: outputDir.appendingPathComponent("\(name).png"))
    }

    private struct Fixture {
        let controller: MuesliController
        let store: DictationStore
        let rush: Int64
        let legal: Int64
        let privateMeeting: Int64
        let normalMeeting: Int64
    }

    private func makeFixture() throws -> Fixture {
        let store = DictationStore(databaseURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("ui-snapshot-\(UUID()).db"))
        try store.migrateIfNeeded()
        let configDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ui-snapshot-config-\(UUID())", isDirectory: true)
        let controller = MuesliController(
            runtime: RuntimePaths(repoRoot: FileManager.default.temporaryDirectory, menuIcon: nil, appIcon: nil, bundlePath: nil),
            dictationStore: store,
            configStore: ConfigStore(supportDirectory: configDirectory)
        )
        let rush = try store.createFolder(name: "Rush")
        let legal = try store.createFolder(name: "Legal")
        _ = try store.createFolder(name: "V12")
        try store.setFolderPrivate(id: legal, isPrivate: true)

        func meeting(_ title: String, notes: String, folder: Int64?) throws -> Int64 {
            let start = Date().addingTimeInterval(-86_400)
            let id = try store.createLiveMeeting(title: title, calendarEventID: nil, startTime: start)
            try store.completeLiveMeeting(id: id, title: title, calendarEventID: nil, startTime: start,
                endTime: start.addingTimeInterval(1800), rawTranscript: "words", formattedNotes: notes,
                micAudioPath: nil, systemAudioPath: nil)
            if let folder { try store.moveMeeting(id: id, toFolder: folder) }
            return id
        }
        let normal = try meeting("Weekly AP review", notes: "## Summary\nInvoices approved; two vendor terms to revisit.", folder: rush)
        let secret = try meeting("Estate planning with counsel", notes: "## Summary\nSettlement structure discussed.", folder: legal)
        let direct = try meeting("Lender call", notes: "## Summary\nTerms reviewed.", folder: nil)
        try store.setMeetingPrivate(id: direct, isPrivate: true)
        let unfiled = try meeting("V12 weekly update", notes: "## Summary\nFund update.", folder: nil)

        let classification = FolderClassificationStore(databaseURL: store.resolvedDatabaseURL)
        let v12 = try #require(try store.listFolders().first { $0.name == "V12" })
        try classification.recordSuggestion(meetingID: unfiled, candidate: .init(
            folderID: v12.id, source: .series, confidence: 0.9, reason: "Same recurring series as 4 meetings in V12"))

        let spoken = Date().addingTimeInterval(-3_600)
        try store.insertDictation(
            text: "Remind me to send the revised term sheet to the lender once legal signs off on the covenant language, and copy the fund controller.",
            durationSeconds: 9, source: "dictation", targetAppName: "Notes", targetAppBundleID: "com.apple.Notes",
            startedAt: spoken, endedAt: spoken.addingTimeInterval(9)
        )

        controller.syncAppState()
        controller.refreshFolderSuggestionInbox()
        return Fixture(controller: controller, store: store, rush: rush, legal: legal, privateMeeting: secret, normalMeeting: normal)
    }

    @Test("meeting list shows the lock on private meetings")
    func meetingList() throws {
        let f = try makeFixture()
        f.controller.appState.selectedTab = .meetings
        try render(MeetingsView(appState: f.controller.appState, controller: f.controller), width: 960, height: 640, name: "01-meetings-list")
    }

    @Test("sidebar shows private folders with a lock")
    func sidebar() throws {
        let f = try makeFixture()
        f.controller.appState.selectedTab = .meetings
        try render(SidebarView(appState: f.controller.appState, controller: f.controller), width: 260, height: 640, name: "02-sidebar")
    }

    @Test("sidebar shows the recording item above Timeline while a meeting records")
    func sidebarRecording() throws {
        let f = try makeFixture()
        f.controller.appState.selectedTab = .timeline
        f.controller.appState.activeMeetingID = f.normalMeeting
        try render(SidebarView(appState: f.controller.appState, controller: f.controller), width: 260, height: 640, name: "05-sidebar-recording")
    }

    @Test("folder suggestions inbox")
    func inbox() throws {
        let f = try makeFixture()
        f.controller.appState.selectedTab = .meetings
        try render(FolderInboxView(appState: f.controller.appState, controller: f.controller), width: 900, height: 420, name: "03-inbox")
    }

    /// The widest a view asks to be when it is offered `width`. A page that asks for more than it
    /// is offered is wider than its window, and clips on both sides.
    private func demandedWidth<V: View>(of view: V, offered width: CGFloat) -> CGFloat {
        NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: 800)).width
    }

    @Test("meeting list and inbox stay inside a narrow pane")
    func narrowPane() throws {
        let f = try makeFixture()
        f.controller.appState.selectedTab = .meetings
        try render(MeetingsView(appState: f.controller.appState, controller: f.controller), width: 240, height: 800, name: "06-meetings-list-narrow")
        try render(FolderInboxView(appState: f.controller.appState, controller: f.controller), width: 240, height: 800, name: "07-inbox-narrow")
        #expect(demandedWidth(of: MeetingsView(appState: f.controller.appState, controller: f.controller), offered: 240) <= 240)
        #expect(demandedWidth(of: FolderInboxView(appState: f.controller.appState, controller: f.controller), offered: 240) <= 240)
    }

    @Test("timeline and dictations stay inside a narrow pane")
    func narrowTimelineAndDictations() throws {
        let f = try makeFixture()
        f.controller.appState.selectedTab = .timeline
        // Showing the iCloud banner in a window sends telemetry, which needs the app's setup. Render
        // the pages without it, and measure the banner on its own below (measuring never shows it).
        f.controller.appState.config.showIOSCompanionPrompt = false
        try render(TimelineView(appState: f.controller.appState, controller: f.controller), width: 240, height: 2200, name: "08-timeline-narrow")
        try render(DictationsView(appState: f.controller.appState, controller: f.controller), width: 240, height: 900, name: "09-dictations-narrow")
        #expect(demandedWidth(of: TimelineView(appState: f.controller.appState, controller: f.controller), offered: 240) <= 240)
        #expect(demandedWidth(of: DictationsView(appState: f.controller.appState, controller: f.controller), offered: 240) <= 240)

        f.controller.appState.config.showIOSCompanionPrompt = true
        #expect(demandedWidth(of: IPhoneBridgeCard(appState: f.controller.appState, controller: f.controller), offered: 240) <= 240)
        #expect(demandedWidth(of: TimelineView(appState: f.controller.appState, controller: f.controller), offered: 240) <= 240)
    }

    private struct SnapshotError: LocalizedError {
        var errorDescription: String? {
            "Custom LLM could not be reached while generating meeting notes. A server with the specified hostname could not be found."
        }
    }

    @Test("meeting header: red Summary chip when the summary failed, green when it worked")
    func statusChips() throws {
        let f = try makeFixture()
        f.controller.appState.selectedTab = .meetings

        let start = Date().addingTimeInterval(-7_200)
        let failedID = try f.store.createLiveMeeting(title: "V12 Weekly Update Call", calendarEventID: nil, startTime: start)
        try f.store.completeLiveMeeting(
            id: failedID, title: "V12 Weekly Update Call", calendarEventID: nil, startTime: start,
            endTime: start.addingTimeInterval(3_600), rawTranscript: "Brian: ship it Friday.",
            formattedNotes: MeetingSummaryClient.summaryFailureNotes(
                transcript: "Brian: ship it Friday.", meetingTitle: "V12 Weekly Update Call", error: SnapshotError()),
            micAudioPath: nil, systemAudioPath: nil)

        let failed = try #require(try f.store.meeting(id: failedID))
        let worked = try #require(try f.store.meeting(id: f.normalMeeting))
        try render(MeetingDetailView(meeting: failed, controller: f.controller, appState: f.controller.appState),
                   width: 1000, height: 360, name: "10-meeting-chips-summary-failed")
        try render(MeetingDetailView(meeting: worked, controller: f.controller, appState: f.controller.appState),
                   width: 1000, height: 360, name: "11-meeting-chips-ok")
        try render(MeetingDetailView(meeting: failed, controller: f.controller, appState: f.controller.appState),
                   width: 680, height: 360, name: "12-meeting-chips-summary-failed-narrow")
    }

    @Test("settings: private meetings, auto export and folder suggestions")
    func settings() throws {
        let f = try makeFixture()
        f.controller.appState.selectedTab = .settings
        f.controller.appState.selectedSettingsPane = .meetings
        f.controller.updateConfig { config in
            config.autoExportMarkdownEnabled = true
            config.autoExportKeepInSync = true
            config.privateTrustedBackends = ["custom_llm"]
        }
        try render(SettingsView(appState: f.controller.appState, controller: f.controller), width: 900, height: 3600, name: "04-settings")
    }
}
