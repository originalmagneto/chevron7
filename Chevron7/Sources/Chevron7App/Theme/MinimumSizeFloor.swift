// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import SwiftUI

/// A minimum size that only raises the content's own minimum, never lowers it.
///
/// `.frame(minWidth:minHeight:)` around the main window's `NavigationSplitView` replaced the
/// split view's minimum with its own: asked for its smallest size, the frame offers the
/// split view 760 points and the split view takes them, so the window let itself shrink
/// below sidebar + content + inspector. AppKit then ran update-constraints passes until it
/// threw "more Update Constraints in Window passes than there are views" and the app
/// crashed (1.4.3, signing screen with the inspector, resized to 1200 x 788). Here the
/// content is measured first and the floor applies only where it asks for less, so the
/// window's minimum follows the visible columns.
struct MinimumSizeFloor: Layout {
    var width: CGFloat
    var height: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let floor = CGSize(width: width, height: height)
        guard let content = subviews.first else { return floor }
        return Self.raise(content.sizeThatFits(proposal), to: floor)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }

    static func raise(_ size: CGSize, to floor: CGSize) -> CGSize {
        CGSize(width: max(size.width, floor.width), height: max(size.height, floor.height))
    }
}

extension View {
    /// The smallest size the view accepts: at least `width` x `height`, more when its
    /// content needs more. See `MinimumSizeFloor`.
    func minimumSizeFloor(width: CGFloat, height: CGFloat) -> some View {
        MinimumSizeFloor(width: width, height: height) { self }
    }
}
