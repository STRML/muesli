import SwiftUI
import MuesliCore

/// Pending folder suggestions for unfiled meetings: accept, pick another folder, or dismiss.
struct FolderInboxView: View {
    let appState: AppState
    let controller: MuesliController

    private var folderPaths: [Int64: String] {
        Dictionary(
            FolderClassificationLLM.choices(from: appState.folders).map { ($0.id, $0.path) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private var meetings: [(id: Int64, rows: [FolderSuggestionInboxRow])] {
        var order: [Int64] = []
        var grouped: [Int64: [FolderSuggestionInboxRow]] = [:]
        for row in appState.folderSuggestionRows {
            let id = row.suggestion.meetingID
            if grouped[id] == nil { order.append(id) }
            grouped[id, default: []].append(row)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
                DashboardPageHeader(title: "Inbox", appState: appState, controller: controller)
                header
                if meetings.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: MuesliTheme.spacing12) {
                        ForEach(meetings, id: \.id) { meeting in
                            meetingCard(meeting.rows)
                        }
                    }
                }
            }
            .frame(maxWidth: 960, alignment: .leading)
            .padding(.horizontal, MuesliTheme.pageInset)
            .padding(.top, MuesliTheme.pageTop)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MuesliTheme.backgroundBase)
    }

    private var header: some View {
        FolderInboxHeader(
            isClassifying: appState.isClassifyingUnfiledMeetings,
            onClassify: { controller.classifyUnfiledMeetings() },
            onStop: { controller.cancelClassifyUnfiledMeetings() }
        )
    }

    private func meetingCard(_ rows: [FolderSuggestionInboxRow]) -> some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            if let first = rows.first {
                Button { controller.showMeetingDocument(id: first.suggestion.meetingID) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(first.meetingTitle)
                            .font(MuesliTheme.headline())
                            .foregroundStyle(MuesliTheme.textPrimary)
                            .lineLimit(1)
                        Text(Self.displayDate(first.meetingStartTime))
                            .font(MuesliTheme.caption())
                            .foregroundStyle(MuesliTheme.textTertiary)
                    }
                }
                .buttonStyle(.plain)
            }
            ForEach(rows) { row in
                suggestionRow(row.suggestion)
            }
        }
        .padding(MuesliTheme.spacing16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerLarge))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerLarge)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private func suggestionRow(_ suggestion: FolderSuggestion) -> some View {
        FolderSuggestionRowView(
            iconName: suggestion.source == .llm ? "sparkles" : "folder",
            folderName: folderPaths[suggestion.folderID] ?? "Folder",
            reason: suggestion.reason,
            folders: appState.folders.map { (id: $0.id, name: folderPaths[$0.id] ?? $0.name) },
            onAccept: { controller.acceptFolderSuggestion(suggestion) },
            onChooseFolder: { controller.moveMeeting(id: suggestion.meetingID, toFolder: $0) },
            onDismiss: { controller.dismissFolderSuggestion(suggestion) }
        )
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            Image(systemName: "tray")
                .font(.system(size: 30, weight: .thin))
                .foregroundStyle(MuesliTheme.textTertiary)
            Text("No folder suggestions")
                .font(MuesliTheme.title3())
                .foregroundStyle(MuesliTheme.textSecondary)
            Text("File a few meetings into folders, then classify unfiled meetings to get suggestions here.")
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textTertiary)
                .frame(maxWidth: 360, alignment: .leading)
        }
        .padding(MuesliTheme.spacing24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerXL))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerXL)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private static func displayDate(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}


/// The Inbox intro and its Classify button: side by side when they fit, stacked when they do not.
struct FolderInboxHeader: View {
    let isClassifying: Bool
    let onClassify: () -> Void
    let onStop: () -> Void

    private var intro: some View {
        Text("Suggested folders for unfiled meetings. Accepting teaches Muesli where similar meetings belong.")
            .font(MuesliTheme.callout())
            .foregroundStyle(MuesliTheme.textTertiary)
    }

    private func controls(fixed: Bool) -> some View {
        HStack(spacing: MuesliTheme.spacing8) {
            if isClassifying {
                ProgressView().controlSize(.small)
                Button("Stop", action: onStop)
            } else {
                Button("Classify Unfiled Meetings", action: onClassify)
            }
        }
        // Beside the intro the button keeps its size; stacked under it, it may shrink to the pane.
        .fixedSize(horizontal: fixed, vertical: true)
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: MuesliTheme.spacing12) {
                intro
                Spacer(minLength: MuesliTheme.spacing12)
                controls(fixed: true)
            }
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                intro.frame(maxWidth: .infinity, alignment: .leading)
                controls(fixed: false)
            }
        }
    }
}

/// One suggestion: the folder and why, with Accept, another folder, and Dismiss. One row when it
/// fits; otherwise the actions wrap under the text.
struct FolderSuggestionRowView: View {
    let iconName: String
    let folderName: String
    let reason: String
    let folders: [(id: Int64, name: String)]
    let onAccept: () -> Void
    let onChooseFolder: (Int64) -> Void
    let onDismiss: () -> Void

    private var summary: some View {
        HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
            Image(systemName: iconName)
                .foregroundStyle(MuesliTheme.textSecondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(folderName)
                    .font(MuesliTheme.callout())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text(reason)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
            }
        }
    }

    private var actions: some View {
        WrappingHStack(spacing: MuesliTheme.spacing8, lineSpacing: MuesliTheme.spacing8) {
            Button("Accept", action: onAccept)
                .buttonStyle(.borderedProminent)
                .fixedSize()
            Menu("Another Folder") {
                ForEach(folders, id: \.id) { folder in
                    Button(folder.name) { onChooseFolder(folder.id) }
                }
            }
            .fixedSize()
            Button("Dismiss", action: onDismiss)
                .fixedSize()
        }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: MuesliTheme.spacing12) {
                summary
                Spacer(minLength: MuesliTheme.spacing8)
                actions
            }
            VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                summary.frame(maxWidth: .infinity, alignment: .leading)
                actions
            }
        }
    }
}
