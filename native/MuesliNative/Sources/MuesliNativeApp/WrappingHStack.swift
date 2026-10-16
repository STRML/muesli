import SwiftUI

/// Lays children out left to right and starts a new line when the next one would pass the proposed
/// width. For rows of buttons, menus and badges: in a plain `HStack` the ones that cannot shrink
/// (`fixedSize`) force the whole page wider than its window, in this they wrap. A child wider than
/// the line is given the line's width, so text truncates instead of overflowing.
struct WrappingHStack: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8
    var alignment: HorizontalAlignment = .leading

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func measure(_ subview: LayoutSubview, maxWidth: CGFloat) -> CGSize {
        let ideal = subview.sizeThatFits(.unspecified)
        guard ideal.width > maxWidth else { return ideal }
        return subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
    }

    private func lines(_ subviews: Subviews, maxWidth: CGFloat) -> (lines: [Line], sizes: [CGSize]) {
        var lines: [Line] = [Line()]
        var sizes: [CGSize] = []
        for index in subviews.indices {
            let size = measure(subviews[index], maxWidth: maxWidth)
            sizes.append(size)
            let isFirst = lines[lines.count - 1].indices.isEmpty
            if !isFirst, lines[lines.count - 1].width + spacing + size.width > maxWidth {
                lines.append(Line())
            }
            var line = lines[lines.count - 1]
            line.width += line.indices.isEmpty ? size.width : spacing + size.width
            line.height = max(line.height, size.height)
            line.indices.append(index)
            lines[lines.count - 1] = line
        }
        return (lines, sizes)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let measured = lines(subviews, maxWidth: proposal.width ?? .infinity).lines
        let height = measured.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(measured.count - 1, 0))
        return CGSize(width: measured.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (laidOut, sizes) = lines(subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for line in laidOut {
            var x = alignment == .trailing ? bounds.maxX - line.width : bounds.minX
            for index in line.indices {
                let size = sizes[index]
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (line.height - size.height) / 2),
                    proposal: ProposedViewSize(width: size.width, height: size.height)
                )
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }
}
