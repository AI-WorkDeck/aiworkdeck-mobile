import SwiftUI

/// Geometry, rather than device identity, decides which pane is visible. Both
/// children remain mounted so folding cannot restart Quick Look or a paid pull.
struct FilePaneGeometry {
    let list: CGRect
    let reader: CGRect
    let listVisible: Bool
    let readerVisible: Bool

    init(size: CGSize, reserved: [CGRect], reading: Bool, showList: Bool, focus: Bool) {
        let full = CGRect(origin: .zero, size: size)
        let hidden = full.offsetBy(dx: size.width, dy: 0)
        guard reading else {
            list = full; reader = hidden; listVisible = true; readerVisible = false
            return
        }
        if showList {
            list = full; reader = hidden; listVisible = true; readerVisible = false
            return
        }
        let division = reserved.first { rect in
            rect.intersects(full) && (rect.height >= size.height * 0.8 || rect.width >= size.width * 0.8)
        }
        if !focus, let division, division.height >= size.height * 0.8,
           division.minX >= 240, size.width - division.maxX >= 240 {
            list = CGRect(x: 0, y: 0, width: division.minX, height: size.height)
            reader = CGRect(x: division.maxX, y: 0, width: size.width - division.maxX, height: size.height)
            listVisible = true; readerVisible = true
        } else if !focus, let division, division.width >= size.width * 0.8,
                  division.minY >= 160, size.height - division.maxY >= 160 {
            reader = CGRect(x: 0, y: 0, width: size.width, height: division.minY)
            list = CGRect(x: 0, y: division.maxY, width: size.width, height: size.height - division.maxY)
            listVisible = true; readerVisible = true
        } else if !focus, division == nil, size.width >= 720, size.width > size.height {
            let width = min(320, size.width * 0.34)
            list = CGRect(x: 0, y: 0, width: width, height: size.height)
            reader = CGRect(x: width, y: 0, width: size.width - width, height: size.height)
            listVisible = true; readerVisible = true
        } else {
            list = showList ? full : hidden
            reader = showList ? hidden : full
            listVisible = showList; readerVisible = !showList
        }
    }
}

struct FilePaneLayout: Layout {
    let geometry: FilePaneGeometry

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, rect) in [geometry.list, geometry.reader].enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + rect.minX, y: bounds.minY + rect.minY),
                                  anchor: .topLeading, proposal: ProposedViewSize(rect.size))
        }
    }
}
