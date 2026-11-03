import SwiftUI
import UIKit

extension View {
    /** Press and hold to get a "Copy" bubble for [text]; nothing has to be selected. */
    /// [below] puts the bubble under the text, for things at the very top of a sheet.
    func copyable(_ text: String?, below: Bool = false) -> some View {
        modifier(CopyOnHold(text: text, below: below))
    }
}

struct CopyOnHold: ViewModifier {
    /** For the build's screenshots: the text whose bubble opens on its own. */
    @MainActor static var demoText: String?

    let text: String?
    var below = false
    @State private var showing = false
    @State private var copied = false
    @State private var hide: Task<Void, Never>?

    func body(content: Content) -> some View {
        if let text, !text.isEmpty {
            content
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(showing ? 0.16 : 0))
                        .padding(-6)
                )
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.4) {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    copied = false
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.65)) { showing = true }
                    later(4) { showing = false }
                }
                .overlay(alignment: below ? .bottomLeading : .topLeading) {
                    if showing {
                        Button {
                            UIPasteboard.general.string = text
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            withAnimation(.easeOut(duration: 0.15)) { copied = true }
                            later(1.1) { showing = false }
                        } label: {
                            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 14).frame(height: 36)
                                .background(Capsule().fill(copied ? Vela.open : Color(hex: 0x303134)))
                                .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                        }
                        .buttonStyle(.plain)
                        .offset(y: below ? 44 : -44)
                        .transition(.scale(scale: 0.5, anchor: below ? .topLeading : .bottomLeading).combined(with: .opacity))
                    }
                }
                .zIndex(showing ? 1 : 0)
                .task {
                    guard Self.demoText == text else { return }
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.65)) { showing = true }
                }
        } else {
            content
        }
    }

    private func later(_ seconds: Double, _ action: @escaping () -> Void) {
        hide?.cancel()
        hide = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.2)) { action() }
        }
    }
}
