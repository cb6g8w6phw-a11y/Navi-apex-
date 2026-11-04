import SwiftUI

/**
 * The short film played when Apex is launched: the logo flips in in 3D with a metallic sheen
 * sweeping over it, the wordmark rises behind it, and a slim progress bar runs underneath.
 * Tapping skips it. `isShown` is bound back to the caller, which drops the overlay.
 */
struct SplashView: View {
    @Binding var isShown: Bool
    @State private var flipped = false
    @State private var risen = false
    @State private var sheen = false
    @State private var bar = false

    var body: some View {
        ZStack {
            // Deep steel backdrop, a shade lighter at the top like light from above.
            LinearGradient(colors: [Color(hex: 0x23282E), Color(hex: 0x15181C), Color(hex: 0x0D0F12)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 26) {
                Spacer()

                // The logo: a card in brushed metal that turns on its Y axis as it arrives.
                ZStack {
                    BrushedMetal()
                        .frame(width: 160, height: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
                        .shadow(color: .black.opacity(0.55), radius: 26, y: 14)
                    Image("Logo")
                        .resizable().scaledToFit()
                        .frame(width: 118, height: 118)
                    // The sheen: a bright band that sweeps across the metal, over and over.
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .fill(LinearGradient(colors: [.clear, .white.opacity(0.75), .clear],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 90, height: 260)
                        .blur(radius: 6)
                        .rotationEffect(.degrees(24))
                        .offset(x: sheen ? 220 : -220)
                }
                .frame(width: 160, height: 160)
                .scaleEffect(flipped ? 1 : 0.35)
                .opacity(flipped ? 1 : 0)
                .rotation3DEffect(.degrees(flipped ? 0 : 92), axis: (x: 0.05, y: 1, z: 0.02),
                                  perspective: 0.55)
                .shadow(color: Color(hex: 0x2DD4BF).opacity(flipped ? 0.35 : 0), radius: 34)

                // The wordmark rises out of the dark a touch behind the logo.
                Text("Apex")
                    .font(.system(size: 44, weight: .heavy, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: [.white, Color(hex: 0x9AA6B2)],
                                                    startPoint: .top, endPoint: .bottom))
                    .offset(y: risen ? 0 : 26)
                    .opacity(risen ? 1 : 0)

                Spacer()

                // A slim progress bar in the route's teal, ticking along like the trip bar.
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.14)).frame(height: 4)
                    Capsule().fill(LinearGradient(colors: [Color(hex: 0x2DD4BF), Color(hex: 0x22D3EE)],
                                                  startPoint: .leading, endPoint: .trailing))
                        .frame(width: bar ? 168 : 12, height: 4)
                }
                .frame(width: 180)
                .padding(.bottom, 90)
            }
        }
        .onTapGesture { dismiss() }
        .onAppear {
            withAnimation(.spring(response: 0.9, dampingFraction: 0.72)) { flipped = true }
            withAnimation(.easeOut(duration: 0.8).delay(0.55)) { risen = true }
            withAnimation(.easeOut(duration: 0.5).delay(0.35)) { bar = true }
            withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) { sheen = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { dismiss() }
        }
        .transition(.opacity)
    }

    private func dismiss() {
        guard isShown else { return }
        withAnimation(.easeOut(duration: 0.45)) { isShown = false }
    }
}
