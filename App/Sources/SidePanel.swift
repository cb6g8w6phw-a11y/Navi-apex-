import SwiftUI

/**
 * The open iPhone Duo (or an iPad) held sideways: Kite's cards move into a panel down the left
 * and the map gets the rest of the screen, the way Apple Maps does on a big screen. The panel
 * stays inside the left half, so nothing sits on the fold down the middle and the car arrow
 * drives on the right half. Phones, and the Duo's outer screen, keep the normal layout.
 */
enum SidePanel {
    /** The panel's width for a screen this size, or 0 for the normal phone layout. */
    static func width(for size: CGSize, h: UserInterfaceSizeClass?, v: UserInterfaceSizeClass?) -> CGFloat {
        guard h == .regular, v == .regular, size.width > size.height, size.width >= 860 else { return 0 }
        return min(420, size.width / 2 - 36)
    }
}

private struct SidePanelKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /** How wide the side panel is, or 0 on a phone. */
    var sidePanel: CGFloat {
        get { self[SidePanelKey.self] }
        set { self[SidePanelKey.self] = newValue }
    }
}

extension View {
    /** With a side panel, squeezes this into the panel on the left; on a phone it stays as it is. */
    @ViewBuilder
    func inSidePanel(_ width: CGFloat) -> some View {
        if width > 0 {
            frame(width: width).frame(maxWidth: .infinity, alignment: .leading)
        } else {
            self
        }
    }

    /** A whole page (Saved, Settings) as the side panel, with the map still showing beside it. */
    @ViewBuilder
    func sidePage(_ width: CGFloat) -> some View {
        if width > 0 {
            frame(width: width)
                .compositingGroup()
                .shadow(color: .black.opacity(0.3), radius: 12, x: 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            self
        }
    }
}
