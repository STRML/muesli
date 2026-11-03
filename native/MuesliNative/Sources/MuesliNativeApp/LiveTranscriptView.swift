// Purpose: Scrolling live transcript view with auto-scroll during active meetings
// Created: 2026-05-22

import AppKit
import Observation
import SwiftUI

enum LiveTranscriptCopyContent {
    static func text(transcript: String, partialYou: String, partialOthers: String) -> String {
        var sections: [String] = []
        let committed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !committed.isEmpty {
            sections.append(committed)
        }
        let others = partialOthers.trimmingCharacters(in: .whitespacesAndNewlines)
        if !others.isEmpty {
            sections.append("Others: \(others)")
        }
        let you = partialYou.trimmingCharacters(in: .whitespacesAndNewlines)
        if !you.isEmpty {
            sections.append("You: \(you)")
        }
        return sections.joined(separator: "\n")
    }
}

/// One speaker turn as flowing text under a quiet header line. The committed text and the
/// still-changing tail share one font and size, so firming a tail up only changes its color.
struct LiveTranscriptParagraphView: View, Equatable {
    let paragraph: LiveTranscriptParagraph
    var onOpen: (() -> Void)? = nil

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.paragraph == rhs.paragraph }

    var body: some View {
        if paragraph.isBoundary {
            HStack(spacing: MuesliTheme.spacing8) {
                Rectangle().fill(MuesliTheme.surfaceBorder).frame(height: 1)
                Text("Resumed")
                    .font(MuesliTheme.font(size: 10, weight: .medium))
                    .foregroundStyle(MuesliTheme.textTertiary)
                Rectangle().fill(MuesliTheme.surfaceBorder).frame(height: 1)
            }
            .padding(.vertical, MuesliTheme.spacing8)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                if let speaker = paragraph.speaker {
                    Text(speaker + (paragraph.timestamp.map { "  \($0)" } ?? ""))
                        .font(MuesliTheme.font(size: 10, weight: .medium))
                        .foregroundStyle(paragraph.isUser ? MuesliTheme.accent : MuesliTheme.textTertiary)
                }
                Text(flowingText)
                    .font(MuesliTheme.font(size: 13))
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, MuesliTheme.spacing8)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(paragraph.isUser ? MuesliTheme.accent.opacity(0.5) : MuesliTheme.surfaceBorder)
                    .frame(width: 2)
            }
            .contentShape(Rectangle())
            .onTapGesture { onOpen?() }
        }
    }

    private var flowingText: AttributedString {
        var committed = AttributedString(paragraph.committed)
        committed.foregroundColor = MuesliTheme.textPrimary
        guard !paragraph.tail.isEmpty else { return committed }
        var tail = AttributedString((paragraph.committed.isEmpty ? "" : " ") + paragraph.tail)
        tail.foregroundColor = MuesliTheme.textTertiary
        return committed + tail
    }
}

@MainActor
@Observable
final class LiveTranscriptPresentationModel {
    var transcript = ""
    var partialYou = ""
    var partialOthers = ""
    var messages: [TranscriptChatMessage] = []
    private(set) var paragraphs: [LiveTranscriptParagraph] = []

    func update(transcript: String, partialYou: String, partialOthers: String) {
        guard self.transcript != transcript ||
                self.partialYou != partialYou ||
                self.partialOthers != partialOthers else { return }

        if transcript != self.transcript {
            if transcript.hasPrefix(self.transcript) {
                let appended = String(transcript.dropFirst(self.transcript.count))
                messages.append(contentsOf: TranscriptChatMessage.messages(
                    from: appended,
                    startingAt: messages.count
                ))
            } else {
                messages = TranscriptChatMessage.messages(from: transcript)
            }
            self.transcript = transcript
        }
        self.partialYou = partialYou
        self.partialOthers = partialOthers
        paragraphs = LiveTranscriptParagraphs.build(
            messages: messages, partialYou: partialYou, partialOthers: partialOthers
        )
    }

    func reset() {
        transcript = ""
        partialYou = ""
        partialOthers = ""
        messages = []
        paragraphs = []
    }
}

struct LiveTranscriptFeedView: View {
    let paragraphs: [LiveTranscriptParagraph]
    var horizontalPadding: CGFloat
    var topPadding: CGFloat
    var bottomPadding: CGFloat
    var onOpen: (() -> Void)? = nil
    /// The live tab reads newest first, so the open paragraph and its growing tail sit on top.
    var newestFirst = false

    var body: some View {
        LazyVStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            if paragraphs.isEmpty {
                Text("Waiting for speech…")
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, MuesliTheme.spacing8)
            } else {
                ForEach(newestFirst ? Array(paragraphs.reversed()) : paragraphs) { paragraph in
                    LiveTranscriptParagraphView(paragraph: paragraph, onOpen: onOpen)
                        .equatable()
                }
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.top, topPadding)
        .padding(.bottom, bottomPadding)
    }
}

struct LiveTranscriptView: View {
    let transcript: String
    /// Provisional streaming tails render above committed captions and remain
    /// outside the durable transcript until their chunk is committed.
    var partialYou: String = ""
    var partialOthers: String = ""
    @State private var presentation = LiveTranscriptPresentationModel()
    @State private var didCopy = false
    @State private var follow = LiveTranscriptFollowState()
    private let topID = "liveTranscriptTop"

    private var input: LiveTranscriptInput {
        .init(transcript: transcript, partialYou: partialYou, partialOthers: partialOthers)
    }

    private func refreshPresentation() {
        presentation.update(transcript: transcript, partialYou: partialYou, partialOthers: partialOthers)
    }

    private var copyText: String {
        LiveTranscriptCopyContent.text(
            transcript: transcript,
            partialYou: partialYou,
            partialOthers: partialOthers
        )
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: 1).id(topID)
                        LiveTranscriptFeedView(
                            paragraphs: presentation.paragraphs,
                            horizontalPadding: MuesliTheme.spacing16,
                            topPadding: 44,
                            bottomPadding: MuesliTheme.spacing8,
                            newestFirst: true
                        )
                    }
                    .background {
                        LiveTranscriptScrollObserver { top in
                            var next = follow
                            let shouldRefresh = next.updateTop(top)
                            if next != follow { follow = next }
                            if shouldRefresh { refreshPresentation() }
                        }
                    }
                    .textSelection(.enabled)
                }
                .onChange(of: input) { _, _ in
                    if follow.receiveUpdate() { refreshPresentation() }
                }
                .onAppear {
                    follow.showLatest()
                    refreshPresentation()
                    proxy.scrollTo(topID, anchor: .top)
                }
                .overlay(alignment: .top) {
                    if follow.hasPendingUpdates {
                        Button {
                            follow.showLatest()
                            refreshPresentation()
                            proxy.scrollTo(topID, anchor: .top)
                        } label: {
                            Label("New messages", systemImage: "arrow.up")
                                .font(MuesliTheme.callout())
                        }
                        .buttonStyle(.bordered)
                        .padding(.top, MuesliTheme.spacing8)
                    }
                }
            }

            Button(action: copyTranscript) {
                HStack(spacing: 6) {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                    Text(didCopy ? "Copied" : "Copy")
                        .font(MuesliTheme.font(size: 12, weight: .semibold))
                }
                .foregroundStyle(didCopy ? MuesliTheme.success : MuesliTheme.textPrimary)
                .padding(.horizontal, MuesliTheme.spacing12)
                .frame(height: 30)
                .background(MuesliTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                .overlay {
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                        .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .disabled(copyText.isEmpty)
            .padding(.top, MuesliTheme.spacing8)
            .padding(.trailing, MuesliTheme.spacing16)
        }
    }

    private func copyTranscript() {
        guard !copyText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyText, forType: .string)
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            didCopy = false
        }
    }
}

private struct LiveTranscriptInput: Equatable {
    let transcript: String
    let partialYou: String
    let partialOthers: String
}

/// Observe the actual clip view: SwiftUI geometry preferences on macOS do not
/// reliably update when the native scroll view moves its content.
private struct LiveTranscriptScrollObserver: NSViewRepresentable {
    var onTopChanged: (CGFloat) -> Void

    func makeNSView(context: Context) -> ObserverView { ObserverView() }
    func updateNSView(_ view: ObserverView, context: Context) {
        view.onTopChanged = onTopChanged
        view.attach()
    }

    final class ObserverView: NSView {
        var onTopChanged: ((CGFloat) -> Void)?
        private weak var clip: NSClipView?
        private var observation: NSObjectProtocol?

        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); attach() }

        func attach() {
            let next = window == nil ? nil : enclosingScrollView?.contentView
            guard next !== clip else { return }
            if let observation { NotificationCenter.default.removeObserver(observation) }
            observation = nil
            clip = next
            guard let next else { return }
            next.postsBoundsChangedNotifications = true
            observation = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: next, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
            report()
        }

        private func report() {
            // Deliver outside SwiftUI layout/update callbacks.
            DispatchQueue.main.async { [weak self] in
                guard let self, let clip = self.clip else { return }
                self.onTopChanged?(-clip.bounds.minY)
            }
        }

        deinit {
            if let observation { NotificationCenter.default.removeObserver(observation) }
        }
    }
}

/// Hold the visible snapshot while reading history. Prepending captions or
/// growing partials cannot shift that snapshot; pending updates appear on return.
struct LiveTranscriptFollowState: Equatable {
    private(set) var isFollowing = true
    private(set) var hasPendingUpdates = false

    mutating func updateTop(_ minY: CGFloat) -> Bool {
        isFollowing = minY >= -24
        guard isFollowing, hasPendingUpdates else { return false }
        hasPendingUpdates = false
        return true
    }

    mutating func receiveUpdate() -> Bool {
        if !isFollowing { hasPendingUpdates = true }
        return isFollowing
    }

    mutating func showLatest() {
        isFollowing = true
        hasPendingUpdates = false
    }
}
