import SwiftUI
import UIKit

/** The spring the sheet settles with. */
private let sheetSnap = Animation.spring(response: 0.32, dampingFraction: 0.85)

/**
 * Vela's draggable bottom sheet: peek, half and full heights. Drag it from anywhere: below full
 * height the whole sheet moves; at full height its list scrolls, and pulling down from the top of
 * the list brings the sheet down.
 */
struct BottomSheet<Header: View, Content: View>: View {
    @Binding var detent: SheetDetent
    let containerHeight: CGFloat
    var peekHeight: CGFloat = 150
    /** Room to keep free above the sheet at full height, for a card that sits at the top. */
    var topClearance: CGFloat = 0
    @ViewBuilder var header: () -> Header
    @ViewBuilder var content: () -> Content
    // When a drag ends, the finger's offset springs away together with the snap to the new
    // height, instead of jumping back first (that jump made the sheet twitch on release).
    @GestureState(resetTransaction: Transaction(animation: sheetSnap)) private var drag: CGFloat = 0
    @GestureState(resetTransaction: Transaction(animation: sheetSnap)) private var bodyDrag: CGFloat = 0
    @State private var contentAtTop = true
    // What the current drag on the list does, chosen once when it starts (keyed by where the
    // finger went down). Choosing again mid-drag made a scroll back up to the top of the list
    // suddenly grab the whole sheet and pull it down.
    @State private var bodyDragMode: (start: CGPoint, movesSheet: Bool)?
    @Environment(\.colorScheme) private var scheme

    static func height(_ d: SheetDetent, container: CGFloat, peek: CGFloat) -> CGFloat {
        switch d {
        case .peek: return peek
        case .half: return container * 0.46
        case .full: return container * 0.94
        }
    }

    private func height(_ d: SheetDetent) -> CGFloat {
        let h = Self.height(d, container: containerHeight, peek: peekHeight)
        return topClearance > 0 ? min(h, containerHeight - topClearance) : h
    }

    private var current: CGFloat {
        let h = height(detent) - drag - bodyDrag
        let top = topClearance > 0 ? containerHeight - topClearance + 20 : containerHeight * 0.96
        return min(max(h, peekHeight * 0.8), top)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                Capsule()
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: 36, height: 4)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
                header()
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            // Drags are measured on the screen, not on the sheet: the sheet moves under the
            // finger, so measuring on the sheet fed that movement back in and made it shake.
            .gesture(
                DragGesture(minimumDistance: 6, coordinateSpace: .global)
                    .updating($drag) { v, s, _ in s = v.translation.height }
                    .onEnded { settle($0) }
            )
            .onTapGesture {
                if detent == .peek { withAnimation(sheetSnap) { detent = .half } }
            }
            content()
                .frame(maxHeight: .infinity, alignment: .top)
                // Below full height the list doesn't scroll: a drag anywhere moves the sheet.
                .scrollDisabled(detent != .full)
                .coordinateSpace(name: SheetTopMarker.space)
                // iOS 18 and later: the list reports its scroll position itself (`.sheetScroll()`).
                // The older marker's position stops updating while the list scrolls on newer iOS,
                // so the sheet thought the list was always at its top and pulled down with it.
                .environment(\.sheetListAtTop, { contentAtTop = $0 })
                .onPreferenceChange(SheetTopKey.self) { y in
                    if #unavailable(iOS 18) { contentAtTop = y >= -2 }
                }
                .overlay(alignment: .bottomTrailing) {
                    if DemoScript.step == "listscroll" {
                        Text(contentAtTop ? "list at top" : "list scrolled")
                            .font(.caption.bold()).padding(6)
                            .background(Capsule().fill(Color.red)).foregroundColor(.white)
                            .padding(.trailing, 16).padding(.bottom, 80)
                    }
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 12, coordinateSpace: .global)
                        .onChanged { v in
                            if bodyDragMode?.start != v.startLocation {
                                bodyDragMode = (v.startLocation, follows(v))
                            }
                        }
                        .updating($bodyDrag) { v, s, _ in
                            if movesSheet(v) { s = v.translation.height }
                        }
                        .onEnded { v in
                            if movesSheet(v) { settle(v) }
                            bodyDragMode = nil
                        }
                )
        }
        .frame(height: current, alignment: .top)
        .frame(maxWidth: .infinity)
        .modifier(SheetGlass(shape: shape, scheme: scheme))
        .clipShape(shape)
        // Below full height it floats just off the screen's edges, the way iOS 26 sheets do.
        .padding(.horizontal, floating ? 8 : 0)
        .padding(.bottom, floating ? 8 : 0)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: floating)
    }

    private var floating: Bool { detent != .full }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: floating ? 34 : 28, style: .continuous)
    }
}

extension BottomSheet {
    /** Whether the drag in progress on the sheet's body was chosen to move the sheet. */
    private func movesSheet(_ v: DragGesture.Value) -> Bool {
        guard let m = bodyDragMode, m.start == v.startLocation else { return false }
        return m.movesSheet
    }

    /** Whether a drag on the sheet's body should move the sheet, judged as it starts: mostly
     *  vertical, and at full height only a pull down that starts with the list at its top. */
    private func follows(_ v: DragGesture.Value) -> Bool {
        guard abs(v.translation.height) > abs(v.translation.width) else { return false }
        return detent != .full || (contentAtTop && v.translation.height > 0)
    }

    private func settle(_ v: DragGesture.Value) {
        let end = height(detent) - v.predictedEndTranslation.height
        let options: [SheetDetent] = [.peek, .half, .full]
        let best = options.min { a, b in
            abs(height(a) - end) < abs(height(b) - end)
        } ?? .half
        if best != detent { UISelectionFeedbackGenerator().selectionChanged() }
        withAnimation(sheetSnap) { detent = best }
    }
}

private struct SheetListAtTopKey: EnvironmentKey {
    static let defaultValue: ((Bool) -> Void)? = nil
}

extension EnvironmentValues {
    /** Set by a bottom sheet; its list calls it whenever the list reaches or leaves its top. */
    var sheetListAtTop: ((Bool) -> Void)? {
        get { self[SheetListAtTopKey.self] }
        set { self[SheetListAtTopKey.self] = newValue }
    }
}

extension View {
    /** Put on a sheet's scrolling list, so the sheet knows when the list is at its top. */
    func sheetScroll() -> some View { modifier(SheetScrollReporter()) }
}

private struct SheetScrollReporter: ViewModifier {
    @Environment(\.sheetListAtTop) private var report

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.onScrollGeometryChange(for: Bool.self) { g in
                g.contentOffset.y + g.contentInsets.top <= 2
            } action: { _, atTop in
                report?(atTop)
            }
        } else {
            content
        }
    }
}

/** Put at the top of a sheet's scrolling list, so the sheet knows when the list is at its top
 *  (used before iOS 18; later versions use `.sheetScroll()`). */
struct SheetTopMarker: View {
    static let space = "sheet-content"

    var body: some View {
        GeometryReader { g in
            Color.clear.preference(key: SheetTopKey.self, value: g.frame(in: .named(Self.space)).minY)
        }
        .frame(height: 0)
    }
}

struct SheetTopKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}


/** The sheet's background: Liquid Glass on iOS 26 and later, matte glass if chosen (or in the Black theme), Kite's frosted look before that. */
private struct SheetGlass<S: Shape>: ViewModifier {
    let shape: S
    let scheme: ColorScheme
    @ObservedObject private var settings = AppSettings.shared

    private var matte: Bool { settings.glassStyle == .matte || settings.theme == .black }

    func body(content: Content) -> some View {
        if matte {
            content.background(
                shape.fill(.ultraThinMaterial)
                    .overlay(shape.fill(settings.theme == .black ? Color.black.opacity(0.58) : Vela.sheet(scheme).opacity(0.56)))
                    .overlay(shape.stroke(Color.white.opacity(scheme == .dark ? 0.10 : 0.45), lineWidth: 0.75))
                    .shadow(color: .black.opacity(0.3), radius: 14, y: -2)
            )
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(
                shape.fill(.ultraThinMaterial)
                    .overlay(shape.fill(Vela.sheet(scheme).opacity(0.60)))
                    .overlay(shape.stroke(Color.white.opacity(scheme == .dark ? 0.12 : 0.5), lineWidth: 0.75))
                    .shadow(color: .black.opacity(0.25), radius: 14, y: -2)
            )
        }
    }
}
