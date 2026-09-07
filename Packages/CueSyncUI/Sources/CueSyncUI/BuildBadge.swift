//
//  BuildBadge.swift
//  CueSyncUI
//
//  The HUD's build badge: one collapsed line that answers "which build is
//  on this phone?" at arm's length, expanding on tap to the full commit /
//  branch / timestamp. All strings come from BuildIdentity, so this view
//  stays thin and the formatting rules stay unit-tested.
//

#if canImport(SwiftUI)
import SwiftUI

/// Collapsed: `1.0 (12) · 4f3a91c*`. Tapped: the full identity.
///
/// Sits at the bottom of the HUD stack, below the control bar — the band
/// the user's thumb already lives in, well clear of the table in the centre
/// of the frame, so nothing occludes the cloth during play.
public struct BuildBadge: View {
    private let identity: BuildIdentity
    @State private var isExpanded = false

    public init(identity: BuildIdentity) {
        self.identity = identity
    }

    /// Dirty builds read orange: at the table that is the difference
    /// between "this is the merged code" and "this is my scratch tree".
    private var tint: Color {
        identity.isDirty ? .orange : .secondary
    }

    public var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
        } label: {
            if isExpanded {
                expanded
            } else {
                collapsed
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("build-badge")
        .accessibilityLabel("Build \(identity.compactLabel)")
        .accessibilityHint(isExpanded ? "Tap to collapse" : "Tap for commit and branch")
    }

    private var collapsed: some View {
        Text(identity.compactLabel)
            // Semibold monospaced at footnote size stays legible at arm's
            // length in a dim room without stealing attention mid-shot.
            .font(.footnote.weight(.semibold).monospaced())
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
    }

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(identity.fields) { field in
                HStack(spacing: 6) {
                    Text(field.label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .leading)
                    Text(field.value)
                        .font(.footnote.weight(.semibold).monospaced())
                        .foregroundStyle(field.label == "Commit" ? tint : .primary)
                }
            }
            if let command = identity.gitShowCommand {
                Text(command)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        // Selectable where the platform allows it inside a button; the
        // mirror page's copy control is the reliable way to grab the SHA.
        .textSelection(.enabled)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
#endif
