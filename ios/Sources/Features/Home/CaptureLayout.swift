import SwiftUI

/// Repositions the header, preview and controls without recreating the camera
/// view. Short windows can scroll to controls instead of clipping them.
struct CaptureLayout: Layout {
    let viewport: CGSize

    private var landscape: Bool { viewport.width > viewport.height }
    private var panelWidth: CGFloat { landscape ? min(360, viewport.width * 0.45) : viewport.width }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let panel = ProposedViewSize(width: panelWidth, height: nil)
        let header = subviews[0].sizeThatFits(panel).height
        let controls = subviews[2].sizeThatFits(panel).height
        return CGSize(width: viewport.width, height: max(viewport.height, header + controls + (landscape ? 0 : 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let panel = ProposedViewSize(width: panelWidth, height: nil)
        let header = subviews[0].sizeThatFits(panel).height
        let controls = subviews[2].sizeThatFits(panel).height
        if landscape {
            let previewWidth = bounds.width - panelWidth
            subviews[0].place(at: CGPoint(x: bounds.minX + previewWidth, y: bounds.minY), anchor: .topLeading,
                              proposal: ProposedViewSize(width: panelWidth, height: header))
            subviews[1].place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: previewWidth, height: viewport.height))
            subviews[2].place(at: CGPoint(x: bounds.minX + previewWidth, y: bounds.minY + header), anchor: .topLeading,
                              proposal: ProposedViewSize(width: panelWidth, height: controls))
        } else {
            subviews[0].place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: header))
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + header), anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: max(0, bounds.height - header - controls)))
            subviews[2].place(at: CGPoint(x: bounds.minX, y: bounds.maxY - controls), anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: controls))
        }
    }
}
