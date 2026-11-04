import SwiftUI

// MARK: - Liquid Glass

/**
 * The Liquid Glass look: on iOS 26 it is the real thing (`glassEffect`), on earlier systems a
 * hand-rolled version of it — the blur material, a light-catching rim and a soft shadow, so the
 * settings feel the same part of the app everywhere.
 */
private struct LiquidGlassEffect: ViewModifier {
    var corner: CGFloat
    var tint: Color?
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if let tint {
                content.glassEffect(.regular.tint(tint).interactive(), in: .rect(cornerRadius: corner))
            } else {
                content.glassEffect(.regular.interactive(), in: .rect(cornerRadius: corner))
            }
        } else {
            content
                .background(.ultraThinMaterial, in: .rect(cornerRadius: corner))
                .overlay(
                    RoundedRectangle(cornerRadius: corner)
                        .strokeBorder(
                            LinearGradient(
                                colors: scheme == .dark
                                    ? [.white.opacity(0.30), .white.opacity(0.05)]
                                    : [.white.opacity(0.95), .white.opacity(0.30)],
                                startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 1))
                .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.12), radius: 14, y: 8)
        }
    }
}

extension View {
    /// Liquid Glass on iOS 26; the closest look earlier systems allow.
    @ViewBuilder
    func liquidGlass(corner: CGFloat = 26, tint: Color? = nil) -> some View {
        modifier(LiquidGlassEffect(corner: corner, tint: tint))
    }
}

// MARK: - Settings

/** The app's settings, redesigned: glass cards over a soft colour wash, search, and the modern
 *  grouped look. Present it where the old settings sheet was shown:
 *
 *      .sheet(isPresented: $model.showSettings) { GlassSettingsView(model: model) }
 */
struct GlassSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    init(model: AppModel) {
        self.model = model
        self.settings = model.settings
    }

    private struct SettingsRow: Identifiable {
        let id: String
        let title: String
        let subtitle: String?
        let icon: String
        let colors: [Color]
    }

    private struct SettingsSection {
        let title: String
        let icon: String
        let rows: [SettingsRow]
    }

    private var sections: [SettingsSection] {
        [
            SettingsSection(title: "My places", icon: "mappin.and.ellipse", rows: [
                SettingsRow(id: "home", title: "Home",
                            subtitle: settings.home?.address ?? "Set it for one-tap directions",
                            icon: "house.fill", colors: [.blue, .cyan]),
                SettingsRow(id: "work", title: "Work",
                            subtitle: settings.work?.address ?? "Set it for one-tap directions",
                            icon: "briefcase.fill", colors: [.indigo, .purple]),
                SettingsRow(id: "parking", title: "Parked car",
                            subtitle: settings.parking?.category ?? "Remember where you parked",
                            icon: "car.fill", colors: [.orange, .pink]),
            ]),
            SettingsSection(title: "Navigation", icon: "location.north.fill", rows: [
                SettingsRow(id: "mode", title: "Default mode", subtitle: "Used when a trip starts",
                            icon: "arrow.triangle.turn.up.right.diamond.fill", colors: [.green, .teal]),
                SettingsRow(id: "voice", title: "Voice guidance", subtitle: "Spoken turn-by-turn directions",
                            icon: "speaker.wave.2.fill", colors: [.purple, .pink]),
                SettingsRow(id: "highways", title: "Avoid highways", subtitle: nil,
                            icon: "road.lanes", colors: [Color(.systemGray), Color(white: 0.30)]),
                SettingsRow(id: "tolls", title: "Avoid tolls", subtitle: nil,
                            icon: "banknote.fill", colors: [.yellow, .orange]),
            ]),
            SettingsSection(title: "Reports & alerts", icon: "exclamationmark.triangle.fill", rows: [
                SettingsRow(id: "wazeOn", title: "Waze reports",
                            subtitle: "Police, crashes and hazards from other drivers",
                            icon: "megaphone.fill", colors: [.cyan, .blue]),
                SettingsRow(id: "wazePolice", title: "Police reports", subtitle: "Show police sightings",
                            icon: "shield.fill", colors: [.red, .orange]),
                SettingsRow(id: "policeRisk", title: "Police risk score",
                            subtitle: "How likely police are on the road ahead",
                            icon: "chart.bar.fill", colors: [.pink, .red]),
                SettingsRow(id: "wazeVoice", title: "Spoken reports",
                            subtitle: "Say reports out loud while driving",
                            icon: "waveform", colors: [.indigo, .cyan]),
            ]),
            SettingsSection(title: "Cameras & speed", icon: "speedometer", rows: [
                SettingsRow(id: "speedCameras", title: "Speed cameras", subtitle: "Warnings for speed cameras",
                            icon: "camera.fill", colors: [.red, .pink]),
                SettingsRow(id: "plateCameras", title: "Number plate cameras", subtitle: "Warnings for ANPR cameras",
                            icon: "video.fill", colors: [.purple, .indigo]),
                SettingsRow(id: "cameraWarnings", title: "Camera warnings",
                            subtitle: "The card and the chime before a camera",
                            icon: "bell.badge.fill", colors: [.orange, .red]),
                SettingsRow(id: "speeding", title: "Speeding alerts", subtitle: "Warn when over the limit",
                            icon: "speedometer", colors: [.orange, .yellow]),
                SettingsRow(id: "aircraft", title: "Police aircraft", subtitle: "Planes and helicopters nearby",
                            icon: "airplane", colors: [.gray, .blue]),
            ]),
            SettingsSection(title: "Traffic & fuel", icon: "fuelpump.fill", rows: [
                SettingsRow(id: "traffic", title: "Live traffic & roadworks",
                            subtitle: "Closures, warnings and faster-route checks",
                            icon: "car.2.fill", colors: [.teal, .cyan]),
                SettingsRow(id: "fuelOn", title: "Fuel prices",
                            subtitle: "The cheapest station along the route",
                            icon: "fuelpump.fill", colors: [.green, .teal]),
                SettingsRow(id: "tank", title: "Tank size", subtitle: "For working out what a stop saves",
                            icon: "drop.fill", colors: [.blue, .cyan]),
                SettingsRow(id: "fuelKey", title: "Tankerkönig key", subtitle: "Needed for fuel prices",
                            icon: "key.fill", colors: [Color(.systemGray), Color(white: 0.30)]),
            ]),
            SettingsSection(title: "Privacy", icon: "hand.raised.fill", rows: [
                SettingsRow(id: "noGoogle", title: "Search without Google",
                            subtitle: "OpenStreetMap results only, nothing sent to Google",
                            icon: "eye.slash.fill", colors: [.indigo, .blue]),
            ]),
            SettingsSection(title: "About", icon: "info.circle.fill", rows: [
                SettingsRow(id: "version", title: "Version", subtitle: nil,
                            icon: "wrench.and.screwdriver.fill", colors: [.gray, .black]),
            ]),
        ]
    }

    private var filtered: [SettingsSection] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return sections }
        return sections.compactMap { section in
            let rows = section.rows.filter {
                $0.title.localizedCaseInsensitiveContains(q)
                    || ($0.subtitle ?? "").localizedCaseInsensitiveContains(q)
            }
            return rows.isEmpty ? nil : SettingsSection(title: section.title, icon: section.icon, rows: rows)
        }
    }

    var body: some View {
        ZStack {
            backdrop
            ScrollView {
                LazyVStack(spacing: 22) {
                    header
                    searchField
                    ForEach(filtered.indices, id: \.self) { i in
                        sectionCard(filtered[i])
                    }
                    footer
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 34)
                .animation(.easeInOut(duration: 0.2), value: search)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "location.north.circle.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(
                    LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: .rect(cornerRadius: 14))
                .shadow(color: .blue.opacity(0.35), radius: 8, y: 5)
            VStack(alignment: .leading, spacing: 2) {
                Text("Settings").font(.title2).bold()
                Text("Vela Navigation").font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 34, height: 34)
            }
            .liquidGlass(corner: 17)
        }
        .padding(.top, 6)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search settings", text: $search)
                .autocorrectionDisabled()
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .liquidGlass(corner: 20)
    }

    @ViewBuilder
    private func sectionCard(_ section: SettingsSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(section.title, systemImage: section.icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.leading, 6)
            VStack(spacing: 0) {
                ForEach(section.rows.indices, id: \.self) { i in
                    row(section.rows[i])
                    if i < section.rows.count - 1 {
                        Rectangle()
                            .fill(.primary.opacity(0.07))
                            .frame(height: 1)
                            .padding(.leading, 62)
                    }
                }
            }
            .padding(.vertical, 6)
            .liquidGlass(corner: 28)
        }
    }

    @ViewBuilder
    private func row(_ r: SettingsRow) -> some View {
        if r.id == "home" || r.id == "work" {
            Button {
                pick(r.id == "home" ? .home : .work)
            } label: {
                rowBody(r)
            }
            .buttonStyle(.plain)
        } else {
            rowBody(r)
        }
    }

    private func rowBody(_ r: SettingsRow) -> some View {
        HStack(spacing: 14) {
            tile(r)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.title).font(.subheadline.weight(.medium))
                if let s = r.subtitle {
                    Text(s).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            control(r)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    private func tile(_ r: SettingsRow) -> some View {
        Image(systemName: r.icon)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(
                LinearGradient(colors: r.colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                in: .rect(cornerRadius: 9))
            .shadow(color: r.colors[0].opacity(0.35), radius: 4, y: 2)
    }

    @ViewBuilder
    private func control(_ r: SettingsRow) -> some View {
        switch r.id {
        case "voice": toggle(\.voice, r)
        case "highways": toggle(\.avoidHighways, r)
        case "tolls": toggle(\.avoidTolls, r)
        case "wazeOn": toggle(\.wazeOn, r)
        case "wazePolice": toggle(\.wazePolice, r)
        case "policeRisk": toggle(\.policeRisk, r)
        case "wazeVoice": toggle(\.wazeVoice, r)
        case "speedCameras": toggle(\.speedCameras, r)
        case "plateCameras": toggle(\.plateCameras, r)
        case "cameraWarnings": toggle(\.cameraWarnings, r)
        case "speeding": toggle(\.speedingAlert, r)
        case "aircraft": toggle(\.policeAircraft, r)
        case "traffic": toggle(\.traffic, r)
        case "fuelOn": toggle(\.fuelOn, r)
        case "noGoogle": toggle(\.noGoogle, r)
        case "mode": modeMenu
        case "tank": tankMenu
        case "fuelKey": keyField
        case "home": valueLabel(settings.home?.name ?? "Set")
        case "work": valueLabel(settings.work?.name ?? "Set")
        case "parking": parkingControl
        case "version": valueLabel("Vela \(version)", chevron: false)
        default: EmptyView()
        }
    }

    private func toggle(_ kp: ReferenceWritableKeyPath<AppSettings, Bool>, _ r: SettingsRow) -> some View {
        Toggle("", isOn: bind(kp))
            .labelsHidden()
            .tint(r.colors[0])
    }

    private func bind(_ kp: ReferenceWritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(get: { settings[keyPath: kp] }, set: { settings[keyPath: kp] = $0 })
    }

    private var modeMenu: some View {
        Menu {
            ForEach([TravelMode.drive, .walk, .ride], id: \.self) { m in
                Button {
                    settings.defaultMode = m
                } label: {
                    Label(modeName(m), systemImage: modeIcon(m))
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(modeName(settings.defaultMode))
                Image(systemName: "chevron.up.chevron.down").font(.footnote)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private var tankMenu: some View {
        Menu {
            ForEach([30, 40, 50, 60, 70, 80], id: \.self) { litres in
                Button("\(litres) L") { settings.fuelTank = Double(litres) }
            }
        } label: {
            HStack(spacing: 5) {
                Text("\(Int(settings.fuelTank)) L")
                Image(systemName: "chevron.up.chevron.down").font(.footnote)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private var keyField: some View {
        TextField("API key", text: Binding(
            get: { settings.fuelKey },
            set: { settings.fuelKey = $0 }))
            .font(.footnote.monospaced())
            .multilineTextAlignment(.trailing)
            .frame(width: 140)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
    }

    @ViewBuilder
    private var parkingControl: some View {
        if settings.parking != nil {
            Button("Remove") { model.clearParking() }
                .font(.subheadline.bold())
                .tint(.red)
        } else {
            Button("Save") { model.saveParking() }
                .font(.subheadline.bold())
                .tint(.blue)
        }
    }

    private func valueLabel(_ text: String, chevron: Bool = true) -> some View {
        HStack(spacing: 5) {
            Text(text).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func pick(_ kind: PickKind) {
        // Close this sheet first, so the app's own "pick a place" sheet can come up.
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            model.picking = kind
        }
    }

    private func modeName(_ m: TravelMode) -> String {
        m == .drive ? "Driving" : m == .walk ? "Walking" : "Riding"
    }

    private func modeIcon(_ m: TravelMode) -> String {
        m == .drive ? "car.fill" : m == .walk ? "figure.walk" : "bicycle"
    }

    private var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"
    }

    private var footer: some View {
        VStack(spacing: 6) {
            Text("Vela \(version)")
            Text("Designed with Liquid Glass")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }

    // MARK: Backdrop

    /** A soft wash of colour behind the glass, the way Liquid Glass needs something to refract. */
    private var backdrop: some View {
        ZStack {
            Color(uiColor: .systemBackground)
            LinearGradient(colors: [.blue.opacity(0.16), .purple.opacity(0.13), .pink.opacity(0.08)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(.blue.opacity(0.25)).frame(width: 300).blur(radius: 70)
                .offset(x: -130, y: -180)
            Circle().fill(.purple.opacity(0.22)).frame(width: 340).blur(radius: 70)
                .offset(x: 140, y: 240)
            Circle().fill(.teal.opacity(0.15)).frame(width: 260).blur(radius: 60)
                .offset(x: 0, y: 520)
        }
        .ignoresSafeArea()
    }
}
