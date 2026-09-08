//
//  HUDBottomInset.swift
//  CueSync AR
//
//  How tall RootView's bottom HUD cluster (control bar + build badge) is
//  right now, published so overlays UNDER it can sit clear of it.
//
//  The calibration controls live inside the AR surface, which is an earlier
//  sibling in RootView's ZStack — so the control bar always draws on top of
//  them. They used to clear it with a hard-coded 84pt, which stopped being
//  true as buttons were added to the bar: the Lock button ended up beneath
//  the toolbar, where it could not be tapped at all (reported from the
//  table, 2026-09-08). Measuring removes the class of bug rather than
//  re-guessing the number.
//

import SwiftUI

/// Preference carrying the measured height of the bottom HUD cluster.
struct HUDBottomInsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    /// Max, not last: several subviews may report, and the tallest is the
    /// one an overlay actually has to clear.
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct HUDBottomInsetEnvironmentKey: EnvironmentKey {
    /// Matches the pre-measurement constant, so a view that renders before
    /// the first measurement lands is still clear of a typical bar rather
    /// than jumping up from zero.
    static let defaultValue: CGFloat = 84
}

extension EnvironmentValues {
    var hudBottomInset: CGFloat {
        get { self[HUDBottomInsetEnvironmentKey.self] }
        set { self[HUDBottomInsetEnvironmentKey.self] = newValue }
    }
}

extension View {
    /// Measure this view's height and publish it as the bottom HUD inset.
    func measuringHUDBottomInset() -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(key: HUDBottomInsetKey.self,
                                       value: proxy.size.height)
            })
    }
}
