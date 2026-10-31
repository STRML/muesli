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

/// New captions pull the panel to the bottom only while the reader is already there. Once they
/// scroll up the panel stays put, and it follows again when they return to the bottom.
struct LiveTranscriptFollowState: Equatable {
    /// True at first render, before any bottom marker has been measured.
    private(set) var isAtBottom = true
    /// `.infinity` means "unloaded, scrolled away" only once a real marker position has been
    /// seen. Before the first caption there is no marker at all, and the panel keeps following.
    private var hasMeasuredMarker = false

    /// How far below the visible area the marker may sit and still count as the bottom.
    static let bottomTolerance: CGFloat = 24

    var shouldFollowNewContent: Bool { isAtBottom }

    /// The single source of truth for the "Scroll to bottom" pill: shown exactly while
    /// auto-scroll is paused.
    var showsScrollToBottomToast: Bool { !isAtBottom }

    /// The reader asked to jump back: re-pin before scrolling so the next caption follows.
    mutating func tapScrollToBottom() {
        isAtBottom = true
    }

    /// A provisional tail that is non-empty and differs from the last one. Only then does a
    /// follower scroll: whitespace-only churn and a tail that went empty need no scroll.
    static func tailChanged(from old: String, to new: String) -> Bool {
        let trimmedNew = new.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedNew.isEmpty && trimmedNew != old.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `markerMinY` is the marker's top edge in the scroll view's space. A lazy stack keeps rows
    /// loaded below the visible area, so whether the marker exists says nothing about whether
    /// the reader can see it. An unloaded marker reports `.infinity`.
    mutating func noteBottomMarker(markerMinY: CGFloat, viewportHeight: CGFloat) {
        guard viewportHeight > 0 else { return }
        if markerMinY.isFinite { hasMeasuredMarker = true } else if !hasMeasuredMarker { return }
        isAtBottom = markerMinY <= viewportHeight + Self.bottomTolerance
    }
}

private struct LiveTranscriptMarkerMinYKey: PreferenceKey {
    static let defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct LiveTranscriptViewportHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct LiveTranscriptFeedView: View {
    static let bottomAnchorID = "liveTranscriptBottom"
    static let scrollSpace = "liveTranscriptScroll"

    let paragraphs: [LiveTranscriptParagraph]
    var horizontalPadding: CGFloat
    var topPadding: CGFloat
    var bottomPadding: CGFloat
    var onOpen: (() -> Void)? = nil
    /// Reports the top edge of the marker after the last caption, in the scroll space named
    /// `LiveTranscriptFeedView.scrollSpace`. Reports `.infinity` while the marker is not loaded.
    var onBottomMarkerChange: ((CGFloat) -> Void)? = nil

    var body: some View {
        LazyVStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            if paragraphs.isEmpty {
                Text("Waiting for speech…")
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, MuesliTheme.spacing8)
            } else {
                ForEach(paragraphs) { paragraph in
                    LiveTranscriptParagraphView(paragraph: paragraph, onOpen: onOpen)
                        .equatable()
                }
                Color.clear
                    .frame(height: 1)
                    .id(Self.bottomAnchorID)
                    .background {
                        GeometryReader { marker in
                            Color.clear.preference(
                                key: LiveTranscriptMarkerMinYKey.self,
                                value: marker.frame(in: .named(Self.scrollSpace)).minY
                            )
                        }
                    }
            }
        }
        .onPreferenceChange(LiveTranscriptMarkerMinYKey.self) { onBottomMarkerChange?($0) }
        .padding(.horizontal, horizontalPadding)
        .padding(.top, topPadding)
        .padding(.bottom, bottomPadding)
    }
}

struct LiveTranscriptView: View {
    let transcript: String
    /// Provisional streaming tails render after committed captions and remain
    /// outside the durable transcript until their chunk is committed.
    var partialYou: String = ""
    var partialOthers: String = ""
    @State private var presentation = LiveTranscriptPresentationModel()
    @State private var follow = LiveTranscriptFollowState()
    @State private var markerMinY: CGFloat = .infinity
    @State private var viewportHeight: CGFloat = 0
    @State private var didCopy = false

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
                    LiveTranscriptFeedView(
                        paragraphs: presentation.paragraphs,
                        horizontalPadding: MuesliTheme.spacing16,
                        topPadding: 44,
                        bottomPadding: MuesliTheme.spacing8,
                        onBottomMarkerChange: {
                            markerMinY = $0
                            follow.noteBottomMarker(markerMinY: $0, viewportHeight: viewportHeight)
                        }
                    )
                    .textSelection(.enabled)
                }
                .coordinateSpace(name: LiveTranscriptFeedView.scrollSpace)
                .background {
                    GeometryReader { viewport in
                        Color.clear.preference(
                            key: LiveTranscriptViewportHeightKey.self,
                            value: viewport.size.height
                        )
                    }
                }
                .onPreferenceChange(LiveTranscriptViewportHeightKey.self) {
                    viewportHeight = $0
                    follow.noteBottomMarker(markerMinY: markerMinY, viewportHeight: $0)
                }
                .onChange(of: transcript) { _, newTranscript in
                    // Decided before the new lines lay out: the marker is still on screen if the
                    // reader was at the bottom.
                    let followsNewLines = follow.shouldFollowNewContent
                    presentation.update(
                        transcript: newTranscript,
                        partialYou: partialYou,
                        partialOthers: partialOthers
                    )
                    if followsNewLines { scrollToBottom(proxy) }
                }
                // Partials grow the open paragraph in place. A reader at the bottom follows a
                // growing tail, which keeps the new lines from pushing the marker out of view and
                // ending the follow. A reader who scrolled up is left alone: the follow decision
                // is read before the new lines lay out.
                .onChange(of: partialYou) { old, new in
                    let followsNewLines = follow.shouldFollowNewContent
                    presentation.update(
                        transcript: transcript,
                        partialYou: new,
                        partialOthers: partialOthers
                    )
                    if followsNewLines, LiveTranscriptFollowState.tailChanged(from: old, to: new) {
                        scrollToBottom(proxy)
                    }
                }
                .onChange(of: partialOthers) { old, new in
                    let followsNewLines = follow.shouldFollowNewContent
                    presentation.update(
                        transcript: transcript,
                        partialYou: partialYou,
                        partialOthers: new
                    )
                    if followsNewLines, LiveTranscriptFollowState.tailChanged(from: old, to: new) {
                        scrollToBottom(proxy)
                    }
                }
                .onAppear {
                    presentation.update(
                        transcript: transcript,
                        partialYou: partialYou,
                        partialOthers: partialOthers
                    )
                    DispatchQueue.main.async {
                        proxy.scrollTo(LiveTranscriptFeedView.bottomAnchorID, anchor: .bottom)
                    }
                }
                .overlay(alignment: .bottom) { scrollToBottomToast(proxy) }
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

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(LiveTranscriptFeedView.bottomAnchorID, anchor: .bottom)
            }
        }
    }

    /// Visible exactly while auto-scroll is paused. Only the pill itself takes hits, so the
    /// transcript underneath keeps scrolling normally.
    private func scrollToBottomToast(_ proxy: ScrollViewProxy) -> some View {
        ZStack {
            if follow.showsScrollToBottomToast {
                Button {
                    follow.tapScrollToBottom()
                    scrollToBottom(proxy)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Scroll to bottom")
                            .font(MuesliTheme.font(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .padding(.horizontal, MuesliTheme.spacing12)
                    .frame(height: 28)
                    .background(MuesliTheme.surfacePrimary)
                    .clipShape(Capsule())
                    .overlay { Capsule().strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1) }
                    .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
                }
                .buttonStyle(.plain)
                .padding(.bottom, MuesliTheme.spacing12)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: follow.showsScrollToBottomToast)
    }
}
