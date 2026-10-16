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
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(MuesliTheme.textTertiary)
                Rectangle().fill(MuesliTheme.surfaceBorder).frame(height: 1)
            }
            .padding(.vertical, MuesliTheme.spacing8)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                if let speaker = paragraph.speaker {
                    Text(speaker + (paragraph.timestamp.map { "  \($0)" } ?? ""))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(paragraph.isUser ? MuesliTheme.accent : MuesliTheme.textTertiary)
                }
                Text(flowingText)
                    .font(.system(size: 13))
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
    /// True at first render, before any bottom marker has been seen.
    private(set) var isAtBottom = true

    var shouldFollowNewContent: Bool { isAtBottom }

    mutating func noteBottomMarker(visible: Bool) {
        isAtBottom = visible
    }
}

struct LiveTranscriptFeedView: View {
    static let bottomAnchorID = "liveTranscriptBottom"

    let paragraphs: [LiveTranscriptParagraph]
    var horizontalPadding: CGFloat
    var topPadding: CGFloat
    var bottomPadding: CGFloat
    var onOpen: (() -> Void)? = nil
    /// Reports whether the marker after the last caption is on screen.
    var onBottomVisibilityChange: ((Bool) -> Void)? = nil

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
                    .onAppear { onBottomVisibilityChange?(true) }
                    .onDisappear { onBottomVisibilityChange?(false) }
            }
        }
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
                        onBottomVisibilityChange: { follow.noteBottomMarker(visible: $0) }
                    )
                    .textSelection(.enabled)
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
                    guard followsNewLines else { return }
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(LiveTranscriptFeedView.bottomAnchorID, anchor: .bottom)
                        }
                    }
                }
                // Partials grow the open paragraph in place. Follow them only when the
                // reader was already at the bottom (decided before layout); a reader who
                // scrolled up is left alone.
                .onChange(of: partialYou) { _, new in
                    let followsNewLines = follow.shouldFollowNewContent
                    presentation.update(
                        transcript: transcript,
                        partialYou: new,
                        partialOthers: partialOthers
                    )
                    if followsNewLines { scrollToBottom(proxy) }
                }
                .onChange(of: partialOthers) { _, new in
                    let followsNewLines = follow.shouldFollowNewContent
                    presentation.update(
                        transcript: transcript,
                        partialYou: partialYou,
                        partialOthers: new
                    )
                    if followsNewLines { scrollToBottom(proxy) }
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
            }

            Button(action: copyTranscript) {
                HStack(spacing: 6) {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                    Text(didCopy ? "Copied" : "Copy")
                        .font(.system(size: 12, weight: .semibold))
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
}
