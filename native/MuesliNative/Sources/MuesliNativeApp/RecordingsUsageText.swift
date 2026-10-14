import SwiftUI
import MuesliCore

/// Current size of saved meeting audio. Computed once off the main actor when it
/// appears and when the budget changes, never on every render.
struct RecordingsUsageText: View {
    let controller: MuesliController
    let budgetGB: Int
    @State private var usageBytes: Int64?

    var body: some View {
        Text(label)
            .font(MuesliTheme.caption())
            .foregroundStyle(MuesliTheme.textTertiary)
            .task(id: budgetGB) {
                let service = controller.recordingRetentionService
                usageBytes = await Task.detached(priority: .utility) { try? service.usageBytes() }.value
            }
    }

    private var label: String {
        guard let usageBytes else { return "Calculating recordings size…" }
        let size = ByteCountFormatter.string(fromByteCount: usageBytes, countStyle: .file)
        return budgetGB == 0
            ? "\(size) of recordings saved. Transcripts and notes are always kept."
            : "\(size) of \(budgetGB) GB used. Oldest audio is removed first; transcripts and notes are always kept."
    }
}
