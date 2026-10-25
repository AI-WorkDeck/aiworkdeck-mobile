import SwiftUI

/// Keep a native split's width preference within the active fold's leading
/// region. Reserved rectangles already include the system-provided margins.
struct SplitSidebarWidth {
    let minimum: CGFloat
    let ideal: CGFloat

    init(size: CGSize, reserved: [CGRect], minimum: CGFloat, ideal: CGFloat) {
        let division = reserved.first {
            $0.height > $0.width && $0.height >= size.height * 0.8 &&
                $0.minY < size.height && $0.maxY > 0 &&
                $0.minX > 0 && $0.maxX < size.width
        }
        self.minimum = division?.minX ?? minimum
        self.ideal = division?.minX ?? ideal
    }
}

extension View {
    func foldAwareSidebarWidth(in geometry: GeometryProxy, minimum: CGFloat, ideal: CGFloat) -> some View {
        let width = SplitSidebarWidth(size: geometry.size, reserved: CaptureLayout.reservedAreas(in: geometry),
                                      minimum: minimum, ideal: ideal)
        // No maximum: a fixed cap can prevent the system from moving its
        // divider to the fold, whose position changes with the available space.
        return navigationSplitViewColumnWidth(min: width.minimum, ideal: width.ideal)
    }
}
