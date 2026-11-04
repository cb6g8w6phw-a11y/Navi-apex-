import SwiftUI

/** First launch: what Kite is, and the one choice that matters (Google's data, or open data only). */
struct WelcomeView: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.colorScheme) private var scheme
    @State private var openOnly = false

    var body: some View {
        // Scrolls with very big text, with the button always in reach at the bottom.
        ScrollView {
        VStack(alignment: .leading, spacing: 22) {
            Spacer(minLength: 20)
            Image("Logo")
                .resizable()
                .frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: 8) {
                Text("Welcome to Apex").font(.largeTitle.weight(.bold))
                Text("Maps, search and turn-by-turn directions with no account and no tracking.")
                    .font(.title3).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 12) {
                option(title: "Best results", detail: "Search, place details, live traffic and routes from Google, asked anonymously. The map itself is open data.",
                       icon: "sparkles", picked: !openOnly) { openOnly = false }
                option(title: "Open data only", detail: "Nothing is sent to Google. Search from OpenStreetMap and routes from open servers.",
                       icon: "lock.shield", picked: openOnly) { openOnly = true }
            }
            Text("You can change this any time in Settings. Next, Apex asks to use your location, so it can show where you are and guide you.")
                .font(.footnote).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                settings.noGoogle = openOnly
                // Someone keeping away from Google isn't asked about Waze, which Google owns.
                if openOnly { settings.wazeAsked = true }
                settings.welcomed = true
            } label: {
                Text("Get started").font(.headline)
                    .frame(maxWidth: .infinity).frame(height: 54)
                    .foregroundColor(Vela.onAccent(scheme))
                    .background(Capsule().fill(Vela.accent(scheme)))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24).padding(.vertical, 12)
            .background(.ultraThinMaterial)
        }
        .background(PageBackdrop())
    }

    private func option(title: String, detail: String, icon: String, picked: Bool, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon).font(.system(size: 20, weight: .semibold)).frame(width: 28)
                    .foregroundColor(picked ? Vela.accent(scheme) : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(detail).font(.subheadline).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22)).foregroundColor(picked ? Vela.accent(scheme) : .secondary)
            }
            .padding(16)
            .glassCard(18)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(picked ? Vela.accent(scheme) : Color.secondary.opacity(0.25), lineWidth: picked ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(.primary)
    }
}

/**
 * Asked once, after the welcome on a fresh install or on first open after updating: whether to
 * turn on live Waze reports. A beta, since Waze could stop it working any day.
 */
struct WazeIntroView: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.colorScheme) private var scheme
    @State private var on = true

    /** Waze still shares police, crash and hazard reports. */
    private static var police: Bool { Waze.shares.contains(.police) }

    var body: some View {
        // Scrolls with very big text, with the button always in reach at the bottom.
        ScrollView {
        VStack(alignment: .leading, spacing: 22) {
            Spacer(minLength: 20)
            HStack(spacing: 10) {
                // Only kinds Waze still shares, so the picture matches what Kite can really show.
                ForEach(Self.police ? [WazeAlert.Kind.police, .accident, .hazard] : [.closure], id: \.self) {
                    WazeBadge(kind: $0, size: 56)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Road alerts").font(.largeTitle.weight(.bold))
                    Text("BETA").font(.caption.weight(.heavy))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .foregroundColor(.white)
                        .background(Capsule().fill(Color(hex: 0xF29900)))
                }
                Text(Self.police
                     ? "Live police, crash and hazard reports from Waze drivers, on the map and as warnings while you drive, plus a police heat map and risk score."
                     : "Live road closures from Waze, on the map and as warnings while you drive.")
                    .font(.title3).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 12) {
                option(title: "Turn on road alerts", detail: "Apex asks Waze anonymously about the area you're looking at and your route. Reports Apex sees are kept only on this phone.",
                       icon: "bell.badge", picked: on) { on = true }
                option(title: "Not now", detail: "Nothing is sent to Waze.", icon: "bell.slash", picked: !on) { on = false }
            }
            Text("This is a beta: Waze doesn't officially allow other apps to read its live map, so it may stop working. You can change this any time in Settings › Road alerts.")
                .font(.footnote).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                settings.waze = on
                settings.wazeAsked = true
            } label: {
                Text("Continue").font(.headline)
                    .frame(maxWidth: .infinity).frame(height: 54)
                    .foregroundColor(Vela.onAccent(scheme))
                    .background(Capsule().fill(Vela.accent(scheme)))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24).padding(.vertical, 12)
            .background(.ultraThinMaterial)
        }
        .background(PageBackdrop())
    }

    private func option(title: String, detail: String, icon: String, picked: Bool, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon).font(.system(size: 20, weight: .semibold)).frame(width: 28)
                    .foregroundColor(picked ? Vela.accent(scheme) : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(detail).font(.subheadline).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22)).foregroundColor(picked ? Vela.accent(scheme) : .secondary)
            }
            .padding(16)
            .glassCard(18)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(picked ? Vela.accent(scheme) : Color.secondary.opacity(0.25), lineWidth: picked ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(.primary)
    }
}
