// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import SwiftUI

/// The main window's column visibility, changed without animation.
///
/// Hiding the sidebar with animation lowers the window's minimum width step by step while
/// AppKit's split view still lays the sidebar out. A frame set below that minimum before the
/// animation ended, during its quarter second or at any time while the window's display was
/// asleep (where the animation never advances), left the window narrower than its columns,
/// and AppKit ran update-constraints passes until it threw "more Update Constraints in Window
/// passes than there are views", the loop that crashed 1.4.3 (see `MinimumSizeFloor`;
/// `docs/WINDOW-RESIZE-LOOP-FINDINGS-2026-10-16.md`). Without the animation the minimum
/// drops in one step, so no frame can fall between the two.
extension Binding where Value == NavigationSplitViewVisibility {
    /// This binding, with every change applied without animation, including the one the
    /// sidebar button in the toolbar makes.
    var withoutAnimation: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { wrappedValue },
            set: { newValue in
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { wrappedValue = newValue }
            }
        )
    }
}

extension NavigationSplitViewVisibility {
    /// What the sidebar command switches to: hidden while the sidebar shows, shown while
    /// it is hidden.
    var togglingSidebar: NavigationSplitViewVisibility {
        self == .detailOnly ? .all : .detailOnly
    }
}
