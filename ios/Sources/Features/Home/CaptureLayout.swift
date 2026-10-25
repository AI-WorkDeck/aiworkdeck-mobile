import SwiftUI

/// Only the frames change across postures. The camera and project browser keep
/// the same structural identity, and each pane owns its scrolling.
struct CaptureLayout: Layout {
    let viewport: CGSize
    var audio = false
    var reservedAreas: [CGRect] = []
    var allowsColumns = true

    struct Regions {
        let content: CGRect
        let controls: CGRect
    }

    static func reservedAreas(in geometry: GeometryProxy) -> [CGRect] {
        if #available(iOS 27.1, *) {
            return (geometry.reservedRegions(kind: .division) + geometry.reservedRegions(kind: .occlusion))
                .filter(\.isActive)
                .map { region in
                    CGRect(x: region.frame.minX - region.margins.leading,
                           y: region.frame.minY - region.margins.top,
                           width: region.frame.width + region.margins.leading + region.margins.trailing,
                           height: region.frame.height + region.margins.top + region.margins.bottom)
                }
                .filter { $0.minX < geometry.size.width && $0.maxX > 0 && $0.minY < geometry.size.height && $0.maxY > 0 }
        }
        return []
    }

    private var verticalDivision: CGRect? {
        reservedAreas.first { $0.height > $0.width && $0.height >= viewport.height * 0.5 && $0.minX > 0 && $0.maxX < viewport.width }
    }

    private var horizontalDivision: CGRect? {
        reservedAreas.first { $0.width >= $0.height && $0.width >= viewport.width * 0.5 && $0.minY > 0 && $0.maxY < viewport.height }
    }

    private var usesColumns: Bool {
        allowsColumns && viewport.width > viewport.height && viewport.width >= 640
    }

    var controlWidth: CGFloat {
        if horizontalDivision != nil { return viewport.width }
        if let division = verticalDivision {
            return audio ? division.minX : viewport.width - division.maxX
        }
        return usesColumns ? min(360, viewport.width * (audio ? 0.4 : 0.35)) : viewport.width
    }

    func regions(controlHeight: CGFloat) -> Regions {
        if let division = horizontalDivision {
            return Regions(content: CGRect(x: 0, y: 0, width: viewport.width, height: division.minY),
                           controls: CGRect(x: 0, y: division.maxY, width: viewport.width,
                                            height: viewport.height - division.maxY))
        }
        if let division = verticalDivision {
            let left = CGRect(x: 0, y: 0, width: division.minX, height: viewport.height)
            let right = CGRect(x: division.maxX, y: 0, width: viewport.width - division.maxX, height: viewport.height)
            return Regions(content: audio ? right : left, controls: audio ? left : right)
        }
        if usesColumns {
            let controls = CGRect(x: audio ? 0 : viewport.width - controlWidth, y: 0,
                                  width: controlWidth, height: viewport.height)
            let content = CGRect(x: audio ? controlWidth : 0, y: 0,
                                 width: viewport.width - controlWidth, height: viewport.height)
            return Regions(content: content, controls: controls)
        }
        // Keep a useful media/materials area even in a short split-screen window.
        // The control pane scrolls if its measured content cannot fit.
        let height = min(controlHeight, viewport.height - min(audio ? 200 : 240, viewport.height * 0.4))
        let controls = CGRect(x: 0, y: audio ? 0 : viewport.height - height, width: viewport.width, height: height)
        let content = CGRect(x: 0, y: audio ? height : 0, width: viewport.width, height: viewport.height - height)
        return Regions(content: content, controls: controls)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { viewport }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let height = subviews[1].sizeThatFits(ProposedViewSize(width: controlWidth, height: nil)).height
        let frames = regions(controlHeight: height)
        for (view, frame) in zip(subviews, [frames.content, frames.controls]) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
}
