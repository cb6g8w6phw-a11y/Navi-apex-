import SwiftUI

/**
 * The car itself: what it is, and everything about it that runs out — the insurance and the
 * technical inspection by date, the oil, the filters and the rest by kilometres. The map ball
 * under the weather opens the dashboard of capsule counters, and the settings page is where
 * the car, the odometer and the intervals live. The odometer ticks up on its own by the
 * distance driven with Apex navigating.
 */

// MARK: Data

/** One thing about the car that wears out: how long it lasts in kilometres (and sometimes months). */
struct CarPart: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var intervalKm: Int
    var intervalMonths: Int
    /** Odometer reading when it was last done. Nil: not noted yet. */
    var lastKm: Int?
    /** When it was last done. Nil: not noted yet. */
    var lastDate: Date?

    init(name: String, intervalKm: Int, intervalMonths: Int = 0, lastKm: Int? = nil, lastDate: Date? = nil) {
        self.name = name
        self.intervalKm = intervalKm
        self.intervalMonths = intervalMonths
        self.lastKm = lastKm
        self.lastDate = lastDate
    }
}

extension AppSettings {
    /** The defaults a new car starts with; every one of them can be changed or added to. */
    static let defaultCarParts: [CarPart] = [
        CarPart(name: "Olej silnikowy", intervalKm: 15000, intervalMonths: 12),
        CarPart(name: "Filtr oleju", intervalKm: 15000, intervalMonths: 12),
        CarPart(name: "Filtr powietrza", intervalKm: 30000, intervalMonths: 24),
        CarPart(name: "Filtr paliwa", intervalKm: 40000, intervalMonths: 48),
        CarPart(name: "Filtr kabinowy", intervalKm: 15000, intervalMonths: 12),
        CarPart(name: "Klocki hamulcowe", intervalKm: 50000),
        CarPart(name: "Rozrząd", intervalKm: 120000, intervalMonths: 60),
    ]
}

// MARK: Status

/** How close a thing is to running out. */
enum CarUrgency: Comparable {
    case ok, soon, overdue
    var order: Int { self == .ok ? 0 : self == .soon ? 1 : 2 }
    static func < (a: CarUrgency, b: CarUrgency) { a.order < b.order }
}

/** A date thing (insurance, inspection) counted in days. */
struct CarDateItem {
    let title: String
    let icon: String
    let date: Date?
    var days: Int? {
        guard let date else { return nil }
        return Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()),
                                               to: Calendar.current.startOfDay(for: date)).day
    }
    var urgency: CarUrgency {
        guard let d = days else { return .ok }
        if d < 0 { return .overdue }
        return d <= 30 ? .soon : .ok
    }
}

/** A wearing part counted in kilometres (and months, when it has a time limit too). */
struct CarPartItem {
    let part: CarPart
    let odometer: Int

    var kmSince: Int? {
        guard let last = part.lastKm else { return nil }
        return max(0, odometer - last)
    }
    var kmLeft: Int? {
        guard let since = kmSince else { return nil }
        return part.intervalKm - since
    }
    /** 0…1, how much of the part's life is used up. Over 1 when overdue. */
    var progress: Double? {
        guard let since = kmSince else { return nil }
        return min(Double(since) / Double(max(part.intervalKm, 1)), 1.5)
    }
    var monthsLeft: Int? {
        guard part.intervalMonths > 0, let last = part.lastDate else { return nil }
        return part.intervalMonths - (Calendar.current.dateComponents([.month],
               from: last, to: Date()).month ?? 0)
    }
    var urgency: CarUrgency {
        if let k = kmLeft, k <= 0 { return .overdue }
        if let m = monthsLeft, m <= 0 { return .overdue }
        if let k = kmLeft, k <= Int(Double(part.intervalKm) * 0.2) { return .soon }
        if let m = monthsLeft, m <= 1 { return .soon }
        return .ok
    }
}

/** Everything the car page and the map ball show, in one place. */
struct CarStatus {
    var insurance = CarDateItem(title: "Ubezpieczenie OC/AC", icon: "shield.checkerboard", date: nil)
    var inspection = CarDateItem(title: "Przegląd techniczny (TÜV)", icon: "wrench.and.screwdriver", date: nil)
    var parts: [CarPartItem] = []

    init(settings: AppSettings) {
        insurance = CarDateItem(title: "Ubezpieczenie OC/AC", icon: "shield.checkerboard", date: settings.insuranceEnd)
        inspection = CarDateItem(title: "Przegląd techniczny (TÜV)", icon: "wrench.and.screwdriver", date: settings.inspectionEnd)
        parts = settings.carParts.map { CarPartItem(part: $0, odometer: settings.carOdometer) }
    }

    /** The one thing that runs out first, for the ball under the weather. */
    var mostUrgent: (text: String, urgency: CarUrgency)? {
        var best: (text: String, urgency: CarUrgency, score: Double)?
        for item in [insurance, inspection] {
            guard let d = item.days else { continue }
            let score = Double(max(d, -99))
            let text = d < 0 ? "\(-d) dni po" : "\(d) dni"
            if best == nil || score < best!.score { best = (text, item.urgency, score) }
        }
        for p in parts {
            guard let k = p.kmLeft else { continue }
            let score = Double(k) / Double(max(p.part.intervalKm, 1)) * 365.0
            if best == nil || score < best!.score {
                best = (k < 0 ? "\(Fmt.thousand(-k)) km po" : "\(Fmt.thousand(k)) km", p.urgency, score)
            }
        }
        guard let b = best else { return nil }
        return (b.text, b.urgency)
    }
}

// MARK: The capsule counter

/** A capsule counter with the app's ombré gradient — orange when a month is left, red when it's over. */
struct CarCapsule: View {
    let title: String
    let icon: String
    let value: String
    let subtitle: String
    var progress: Double? = nil
    let urgency: CarUrgency

    private var colors: [Color] {
        switch urgency {
        case .ok: [Color(hex: 0x2DD4BF), Color(hex: 0x22D3EE)]
        case .soon: [Color(hex: 0xF59E0B), Color(hex: 0xF97316)]
        case .overdue: [Color(hex: 0xEF4444), Color(hex: 0xB91C1C)]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                Text(value).font(.system(size: 15, weight: .heavy)).monospacedDigit()
            }
            .foregroundColor(.white)
            if let p = progress {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.25))
                        Capsule().fill(Color.white.opacity(0.9))
                            .frame(width: max(6, g.size.width * CGFloat(min(p, 1))))
                    }
                }
                .frame(height: 5)
            }
            Text(subtitle).font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.85))
                .lineLimit(1).minimumScaleFactor(0.75)
        }
        .padding(12)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.black.opacity(0.08))
            }
        )
    }
}

// MARK: The map ball

/** The car under the weather: the most urgent counter at a glance, in the same glass circle. */
struct CarBall: View {
    let status: CarStatus
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(spacing: 0) {
                Image(systemName: "car.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(tint)
                Text(urgent?.text ?? "—")
                    .font(.system(size: 12, weight: .bold))
                    .monospacedDigit()
                    .foregroundColor(tint)
                    .lineLimit(1).minimumScaleFactor(0.5)
            }
            .frame(width: 46, height: 46)
            .glassButton(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Moje auto")
    }

    private var tint: Color {
        urgent.map { color($0.urgency) } ?? Color(hex: 0x0F9D58)
    }

    private var urgent: (text: String, urgency: CarUrgency)? { status.mostUrgent }

    private func color(_ u: CarUrgency) -> Color {
        switch u {
        case .ok: return Color(hex: 0x0F9D58)
        case .soon: return Color(hex: 0xF59E0B)
        case .overdue: return Color(hex: 0xD93025)
        }
    }
}

// MARK: The dashboard sheet

/** The car's counters as capsules, and below them the page where everything is set. */
struct CarSheet: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            CarPage(settings: settings, showClose: true)
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: The page (sheet and settings share it)

struct CarPage: View {
    @ObservedObject var settings: AppSettings
    /** The sheet shows a close button; pushed from Settings it already has a back arrow. */
    var showClose = false
    @Environment(\.dismiss) private var dismiss

    private var status: CarStatus { CarStatus(settings: settings) }
    private let fuels: [(String, String)] = [
        ("diesel", "Diesel"), ("e10", "Benzyna E10"), ("e5", "Benzyna Super"),
        ("lpg", "LPG"), ("hybrid", "Hybryda"), ("electric", "Elektryczny"),
    ]

    var body: some View {
        Form {
            Section("Status") {
                if nothingTracked {
                    Text("Ustaw model, przebieg i daty poniżej — tutaj pojawią się odliczania.")
                        .font(.footnote).foregroundColor(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        if let d = status.insurance.days {
                            CarCapsule(title: status.insurance.title, icon: status.insurance.icon,
                                       value: d < 0 ? "po \(-d) dni" : "\(d) dni",
                                       subtitle: "do \(dateText(settings.insuranceEnd))",
                                       urgency: status.insurance.urgency)
                        } else {
                            CarCapsule(title: "Ubezpieczenie OC/AC", icon: "shield.checkerboard",
                                       value: "—", subtitle: "data niewpisana", urgency: .ok)
                        }
                        if let d = status.inspection.days {
                            CarCapsule(title: status.inspection.title, icon: status.inspection.icon,
                                       value: d < 0 ? "po \(-d) dni" : "\(d) dni",
                                       subtitle: "do \(dateText(settings.inspectionEnd))",
                                       urgency: status.inspection.urgency)
                        } else {
                            CarCapsule(title: "Przegląd techniczny (TÜV)", icon: "wrench.and.screwdriver",
                                       value: "—", subtitle: "data niewpisana", urgency: .ok)
                        }
                        ForEach(status.parts, id: \.part.id) { p in
                            if let left = p.kmLeft {
                                CarCapsule(title: p.part.name, icon: "gearshape.fill",
                                           value: left < 0 ? "po \(Fmt.thousand(-left)) km" : "za \(Fmt.thousand(left)) km",
                                           subtitle: "co \(Fmt.thousand(p.part.intervalKm)) km"
                                               + (p.monthsLeft != nil && p.monthsLeft! <= 0 ? " • termin czasu minął"
                                                  : p.part.lastKm != nil ? " • ostatnio przy \(Fmt.thousand(p.part.lastKm!)) km" : ""),
                                           progress: p.progress, urgency: p.urgency)
                            } else {
                                CarCapsule(title: p.part.name, icon: "gearshape.fill",
                                           value: "—", subtitle: "wpisz przebieg ostatniej wymiany",
                                           urgency: .ok)
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
                }
            }

            Section(header: Text("Auto"),
                    footer: Text("Przebieg sam rośnie o każdy kilometr przejechany z włączoną nawigacją.")) {
                Toggle(isOn: $settings.carBallOn) { SettingLabel("Ikona auta na mapie", icon: "map", color: 0x7C3AED) }
                TextField("Model (np. VW Golf 7)", text: $settings.carName)
                Picker(selection: $settings.carFuel) {
                    ForEach(fuels, id: \.0) { Text($0.1).tag($0.0) }
                } label: { SettingLabel("Paliwo", icon: "drop.fill", color: 0x0891B2) }
                Stepper(value: $settings.carOdometer, in: 0...1_000_000, step: 500) {
                    SettingLabel("Przebieg: \(Fmt.thousand(settings.carOdometer)) km", icon: "gauge.with.needle.fill", color: 0x16A34A)
                }
                .onChange(of: settings.carOdometer) { _ in
                    Haptics.light()
                }
                // Typing the odometer in, for when the whole number has to jump at once.
                HStack {
                    Text("Wpisz stan licznika").font(.footnote).foregroundColor(.secondary)
                    Spacer()
                    TextField("0", text: odoText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 120)
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    Text("km").font(.footnote).foregroundColor(.secondary)
                }
            }

            Section("Terminy") {
                DatePicker("Ubezpieczenie do", selection: dateBinding(\.insuranceEnd), displayedComponents: .date)
                DatePicker("Przegląd (TÜV) do", selection: dateBinding(\.inspectionEnd), displayedComponents: .date)
            }

            Section(header: Text("Olej, filtry i reszta"),
                    footer: Text("Wpisz, przy jakim przebiegu ostatnio coś wymieniono — pasek pokaże, ile zostało do następnej wymiany. Przesuń w lewo, żeby usunąć pozycję.")) {
                ForEach($settings.carParts) { $part in
                    CarPartRow(part: $part)
                }
                .onDelete { settings.carParts.remove(atOffsets: $0) }
                Button {
                    settings.carParts.append(CarPart(name: "Nowa pozycja", intervalKm: 20000))
                } label: {
                    Label("Dodaj pozycję", systemImage: "plus.circle.fill")
                }
            }
        }
        .toolbar {
            if showClose {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Zamknij") { dismiss() }
                }
            }
        }
        .environment(\.locale, Locale(identifier: "pl_PL"))
        .kiteList()
    }

    /** The typed odometer: digits only, capped, empty when the car is brand new. */
    private var odoText: Binding<String> {
        Binding(
            get: { settings.carOdometer > 0 ? "\(settings.carOdometer)" : "" },
            set: { s in
                let digits = s.filter(\.isNumber)
                settings.carOdometer = min(Int(digits) ?? 0, 1_000_000)
            }
        )
    }

    private var nothingTracked: Bool {
        settings.insuranceEnd == nil && settings.inspectionEnd == nil
            && !settings.carParts.contains { $0.lastKm != nil }
    }

    /** A DatePicker that can sit on top of a date that isn't set yet: it writes only when touched. */
    private func dateBinding(_ key: WritableKeyPath<AppSettings, Date?>) -> Binding<Date> {
        Binding(
            get: { settings[keyPath: key] ?? Date().addingTimeInterval(30 * 24 * 3600) },
            set: { v in
                switch key {
                case \.insuranceEnd: settings.insuranceEnd = v
                case \.inspectionEnd: settings.inspectionEnd = v
                default: break
                }
            }
        )
    }

    private func dateText(_ d: Date?) -> String {
        guard let d else { return "—" }
        let f = DateFormatter()
        f.dateFormat = "d MMMM yyyy"
        return f.string(from: d)
    }
}

/** One wearing part: its interval, and the odometer reading (and date) it was last done at. */
struct CarPartRow: View {
    @Binding var part: CarPart

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Nazwa", text: $part.name)
                .font(.system(size: 15, weight: .semibold))
            Stepper(value: $part.intervalKm, in: 1000...300_000, step: 1000) {
                Text("co \(Fmt.thousand(part.intervalKm)) km").font(.footnote).foregroundColor(.secondary)
            }
            HStack {
                Text("ostatnio przy").font(.footnote).foregroundColor(.secondary)
                Spacer()
                TextField("km", text: kmText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 110)
                    .font(.footnote.monospacedDigit())
                Text("km").font(.footnote).foregroundColor(.secondary)
            }
            if part.intervalMonths > 0 {
                Stepper(value: $part.intervalMonths, in: 0...120, step: 6) {
                    Text(part.intervalMonths == 0 ? "bez limitu czasu"
                         : "co \(part.intervalMonths) mies.").font(.footnote).foregroundColor(.secondary)
                }
                HStack {
                    Text("wymieniono").font(.footnote).foregroundColor(.secondary)
                    Spacer()
                    if part.lastDate != nil {
                        DatePicker("", selection: dateBinding, displayedComponents: .date)
                            .labelsHidden()
                            .environment(\.locale, Locale(identifier: "pl_PL"))
                        Button {
                            withAnimation { part.lastDate = nil }
                        } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                            .buttonStyle(.plain)
                    } else {
                        Button("dodaj datę") { part.lastDate = Date() }
                            .font(.footnote)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    /** The odometer field: free typing, empty when nothing is noted. */
    private var kmText: Binding<String> {
        Binding(
            get: { part.lastKm.map { "\($0)" } ?? "" },
            set: { s in
                let digits = s.filter(\.isNumber)
                part.lastKm = digits.isEmpty ? nil : Int(digits)
            }
        )
    }

    private var dateBinding: Binding<Date> {
        Binding(get: { part.lastDate ?? Date() }, set: { part.lastDate = $0 })
    }
}
