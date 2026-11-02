import SwiftUI

/// Keep one set of focusable children while changing the arrangement. Alternative
/// ViewThatFits trees can replace active editors and complicate a sheet's initial
/// responder graph. The proposal chooses the arrangement without publishing state.
struct AdaptiveStack: Layout {
    var minimumColumnWidth: CGFloat? = nil
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let requiredWidth = horizontalWidth(subviews)
        let layout = arrangement(width: proposal.width ?? requiredWidth, requiredWidth: requiredWidth)
        var layoutCache = layout.makeCache(subviews: subviews)
        return layout.sizeThatFits(proposal: ProposedViewSize(width: proposal.width ?? requiredWidth, height: proposal.height),
                                   subviews: subviews, cache: &layoutCache)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrangement(width: bounds.width, requiredWidth: horizontalWidth(subviews))
        var layoutCache = layout.makeCache(subviews: subviews)
        layout.placeSubviews(in: bounds, proposal: ProposedViewSize(width: bounds.width, height: proposal.height),
                             subviews: subviews, cache: &layoutCache)
    }

    private func horizontalWidth(_ subviews: Subviews) -> CGFloat {
        let widths = subviews.map { minimumColumnWidth ?? $0.sizeThatFits(.unspecified).width }
        return widths.reduce(0, +) + spacing * CGFloat(max(0, subviews.count - 1))
    }

    private func arrangement(width: CGFloat, requiredWidth: CGFloat) -> AnyLayout {
        width >= requiredWidth
            ? AnyLayout(HStackLayout(alignment: .top, spacing: spacing))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
    }
}
