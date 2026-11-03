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

    static let navTeal = Color(hex: 0x0F766E)
    static let navMint = Color(hex: 0x2DD4BF)
}

/** The colour and symbol of a warning ahead. */
private func alertLook(_ kind: String?) -> (symbol: String, color: Color) {
    switch kind {
    case "closure": return ("nosign", Color(hex: 0xFF5A52))
    case "roadworks": return ("hammer.fill", Color(hex: 0xFFC400))
    case "camera": return ("camera.fill", Color(hex: 0xFFB300))
    default: return ("exclamationmark.triangle.fill", Color(hex: 0xFF9A3D))
    }
}

/** The warning line, when there is one. */
private struct AlertLine: View {
    let state: NavActivityAttributes.ContentState

    var body: some View {
        if let text = state.alert {
            let look = alertLook(state.alertKind)
            HStack(spacing: 6) {
                Image(systemName: look.symbol).font(.system(size: 12, weight: .bold))
                Text(text).font(.system(size: 13, weight: .bold)).lineLimit(1)
            }
            .foregroundColor(look.color)
        }
    }
}

private struct SpeedChip: View {
    let state: NavActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 4) {
            Text("\(state.speedKmh)").font(.system(size: 15, weight: .heavy, design: .rounded)).monospacedDigit()
            Text("km/h").font(.system(size: 10, weight: .semibold)).opacity(0.7)
            if let limit = state.limitKmh {
                Text("\(limit)")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundColor(.black)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.white))
                    .overlay(Circle().stroke(Color(hex: 0xD93025), lineWidth: 2.5))
            }
        }
    }
}

/** The lock screen and notification banner. */
private struct LockScreenNav: View {
    let state: NavActivityAttributes.ContentState
    let destination: String

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                Image(systemName: state.symbol)
                    .font(.system(size: 38, weight: .heavy))
                    .frame(width: 54)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.rerouting ? "Rerouting…" : state.distance)
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                    Text(state.street)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                        .opacity(0.92)
                }
                Spacer(minLength: 0)
                SpeedChip(state: state)
            }
            AlertLine(state: state)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Label(state.remaining, systemImage: "clock").font(.system(size: 14, weight: .bold))
                Spacer()
                Text(state.remainingDistance).font(.system(size: 14, weight: .semibold)).opacity(0.85)
                Spacer()
                Label(state.arrival, systemImage: "flag.checkered").font(.system(size: 14, weight: .bold))
            }
        }
        .foregroundColor(.white)
        .padding(16)
    }
}

struct NavLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NavActivityAttributes.self) { context in
            LockScreenNav(state: context.state, destination: context.attributes.destination)
                .activityBackgroundTint(Color.navTeal)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.symbol)
                        .font(.system(size: 34, weight: .heavy))
                        .foregroundColor(Color.navMint)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(context.state.rerouting ? "…" : context.state.distance)
                            .font(.system(size: 26, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        SpeedChip(state: context.state)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.street)
                        .font(.system(size: 17, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        AlertLine(state: context.state)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack {
                            Label(context.state.remaining, systemImage: "clock").font(.system(size: 14, weight: .bold))
                            Spacer()
                            Text(context.state.remainingDistance).font(.system(size: 14, weight: .semibold)).opacity(0.85)
                            Spacer()
                            Label(context.state.arrival, systemImage: "flag.checkered").font(.system(size: 14, weight: .bold))
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.symbol)
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundColor(Color.navMint)
            } compactTrailing: {
                Text(context.state.rerouting ? "…" : context.state.distance)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: 56)
            } minimal: {
                Image(systemName: context.state.symbol)
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundColor(Color.navMint)
            }
            .keylineTint(Color.navMint)
        }
    }
}
