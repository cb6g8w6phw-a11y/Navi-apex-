import ActivityKit
import SwiftUI
import WidgetKit

@main
struct ApexWidgets: WidgetBundle {
    var body: some Widget {
        NavLiveActivity()
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    static let navMint = Color(hex: 0x2DD4BF)
    static let navRed = Color(hex: 0xE11D48)
}

/** The posted limit, drawn as a sign. Falls back to the current speed when the road has no limit. */
private struct LimitSign: View {
    let state: NavActivityAttributes.ContentState
    var wide = false

    var body: some View {
        VStack(spacing: 1) {
            if let limit = state.limitKmh {
                Text("\(limit)")
                    .font(.system(size: wide ? 18 : 15, weight: .heavy, design: .rounded))
                    .foregroundColor(.black)
                    .frame(width: wide ? 40 : 32, height: wide ? 40 : 32)
                    .background(Circle().fill(Color.white))
                    .overlay(Circle().stroke(Color.navRed, lineWidth: wide ? 3 : 2.5))
                Text("LIMIT")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white.opacity(0.65))
            } else {
                Text("\(state.speedKmh)")
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                Text("km/h")
                    .font(.system(size: 8, weight: .semibold))
                    .opacity(0.65)
            }
        }
    }
}

private struct CameraLine: View {
    let state: NavActivityAttributes.ContentState

    var body: some View {
        if let text = state.alert {
            let camera = state.alertKind == "camera"
            HStack(spacing: 6) {
                Image(systemName: camera ? "shield.lefthalf.filled" : "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .bold))
                Text(text)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(camera ? Color(hex: 0x4C0519) : Color(hex: 0x7C2D12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(camera ? Color.navRed : Color(hex: 0xF59E0B), lineWidth: 1)
            )
        }
    }
}

private struct EndNavButton: View {
    var body: some View {
        if #available(iOS 17.0, *) {
            Button(intent: EndTripIntent()) {
                Label("Zakończ nawigację", systemImage: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(Capsule().fill(Color.navRed))
            }
            .buttonStyle(.plain)
        }
    }
}

private struct MuteNavButton: View {
    let muted: Bool

    var body: some View {
        if #available(iOS 17.0, *) {
            Button(intent: MuteTripIntent()) {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white.opacity(0.85))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
        }
    }
}

/** The card from the island and the lock screen: route, next exit, limit, camera, stop. */
private struct IslandCard: View {
    let state: NavActivityAttributes.ContentState
    var roomy = false

    var body: some View {
        VStack(alignment: .leading, spacing: roomy ? 10 : 8) {
            HStack(spacing: 8) {
                Image(systemName: "location.north.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(Color(hex: 0x34D399))
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.rerouting ? "Szukam trasy…" : "Aktywna trasa \(state.routeTitle)")
                        .font(.system(size: roomy ? 15 : 13, weight: .bold))
                        .lineLimit(1)
                    Text(state.routeLine)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.62))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                MuteNavButton(muted: state.muted)
            }
            HStack(spacing: 10) {
                Image(systemName: state.symbol)
                    .font(.system(size: roomy ? 22 : 18, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: roomy ? 44 : 36, height: roomy ? 44 : 36)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(hex: 0x059669)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.arrived ? state.distance : state.distance)
                        .font(.system(size: roomy ? 22 : 18, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                    Text(state.street)
                        .font(.system(size: roomy ? 13 : 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.78))
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                LimitSign(state: state, wide: roomy)
            }
            CameraLine(state: state)
            EndNavButton()
        }
        .foregroundColor(.white)
    }
}

/** The lock screen and notification banner. */
private struct LockScreenNav: View {
    let state: NavActivityAttributes.ContentState

    var body: some View {
        IslandCard(state: state, roomy: true)
            .padding(14)
    }
}

struct NavLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NavActivityAttributes.self) { context in
            LockScreenNav(state: context.state)
                .activityBackgroundTint(Color.black)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.symbol)
                        .font(.system(size: 26, weight: .heavy))
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.arrived ? "OK" : context.state.distance)
                        .font(.system(size: 18, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.street)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    IslandCard(state: context.state)
                        .padding(.horizontal, 2)
                }
            } compactLeading: {
                Image(systemName: context.state.symbol)
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(.white)
            } compactTrailing: {
                Text(context.state.arrived ? "OK" : context.state.distance)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: 56)
            } minimal: {
                Image(systemName: context.state.alertKind == "camera" ? "camera.fill" : context.state.symbol)
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundColor(context.state.alertKind == "camera" ? Color.navRed : Color.navMint)
            }
            .widgetURL(URL(string: "kite://nav"))
            .keylineTint(context.state.alertKind == "camera" ? Color.navRed : Color.navMint)
        }
    }
}
