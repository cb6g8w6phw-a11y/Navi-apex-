import AVKit
import CoreLocation
import MediaPlayer
import SwiftUI
import UIKit

// MARK: - Music, wired into navigation

/** Apple Music on the system player. Voice prompts already duck it; these controls ride along. */
@MainActor
final class NowPlay: ObservableObject {
    static let shared = NowPlay()

    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var playing = false
    @Published var elapsed: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var art: UIImage?
    @Published private(set) var lyrics = ""
    @Published private(set) var allowed = false
    @Published var scrubbing = false

    private let player = MPMusicPlayerController.systemMusicPlayer
    private var timer: Timer?
    private var tokens: [NSObjectProtocol] = []
    private var attached = false
    /// The system player was going before a voice prompt. Live Container does not resume it on its own.
    private var resumeAfterVoice = false

    private init() {}

    func attach() {
        guard !attached else { refresh(); return }
        attached = true
        MPMediaLibrary.requestAuthorization { status in
            Task { @MainActor in
                self.allowed = status == .authorized
                guard self.allowed else { return }
                let was = self.player.playbackState
                self.player.beginGeneratingPlaybackNotifications()
                let center = NotificationCenter.default
                self.tokens.append(center.addObserver(forName: .MPMusicPlayerControllerNowPlayingItemDidChange, object: self.player, queue: .main) { _ in
                    Task { @MainActor in NowPlay.shared.refresh() }
                })
                self.tokens.append(center.addObserver(forName: .MPMusicPlayerControllerPlaybackStateDidChange, object: self.player, queue: .main) { _ in
                    Task { @MainActor in NowPlay.shared.refresh() }
                })
                self.refresh()
                if was == .playing, self.player.playbackState != .playing { self.player.play() }
                self.timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                    Task { @MainActor in NowPlay.shared.tick() }
                }
            }
        }
    }

    func refresh() {
        guard allowed else { return }
        let item = player.nowPlayingItem
        title = item?.title ?? ""
        artist = item?.artist ?? item?.albumArtist ?? ""
        duration = item?.playbackDuration ?? 0
        lyrics = (item?.value(forProperty: MPMediaItemPropertyLyrics) as? String) ?? ""
        art = item?.artwork?.image(at: CGSize(width: 360, height: 360))
        playing = player.playbackState == .playing
        if !scrubbing { elapsed = max(0, player.currentPlaybackTime) }
    }

    func tick() {
        guard allowed, !scrubbing else { return }
        playing = player.playbackState == .playing
        if playing { elapsed = max(0, player.currentPlaybackTime) }
    }

    func toggle() {
        guard allowed else { attach(); return }
        if player.playbackState == .playing { player.pause() } else { player.play() }
        refresh()
    }

    func next() { guard allowed else { return }; player.skipToNextItem(); refresh() }
    func previous() { guard allowed else { return }; player.skipToPreviousItem(); refresh() }

    /// Called just before a spoken instruction, so the song can be started again afterwards.
    func prepareForVoice() {
        if player.playbackState == .playing { resumeAfterVoice = true }
    }

    /// Live Container drops the system player when this app takes the audio session. Put the song back.
    func restoreAfterVoice() {
        let want = resumeAfterVoice
        resumeAfterVoice = false
        guard want, allowed else { return }
        if player.playbackState != .playing { player.play() }
    }

    func seek(_ t: Double) {
        guard allowed else { return }
        player.currentPlaybackTime = max(0, t)
        elapsed = player.currentPlaybackTime
    }

    var remainingLabel: String {
        let left = max(0, duration - elapsed)
        return "-" + Self.clock(left)
    }

    static func clock(_ t: Double) -> String {
        let s = max(0, Int(t.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .label
        v.activeTintColor = UIColor(red: 0.18, green: 0.83, blue: 0.75, alpha: 1)
        v.prioritizesVideoDevices = false
        return v
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

/** A music app Apex can open. Apple Music is the only one iOS lets us pause and skip. */
struct MusicExtra: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var link: String
}

struct MusicTarget: Identifiable, Sendable {
    let id: String
    let name: String
    let symbol: String
    let color: UInt32
    let link: String
    let store: String?
    var isApple: Bool { id == "apple" }
}

enum MusicCatalog {
    static let builtins: [MusicTarget] = [
        MusicTarget(id: "apple", name: "Apple Music", symbol: "applelogo", color: 0xFA2D48, link: "music://", store: nil),
        MusicTarget(id: "spotify", name: "Spotify", symbol: "music.note.list", color: 0x1DB954, link: "spotify://", store: "https://apps.apple.com/app/spotify/id324684580"),
        MusicTarget(id: "ytmusic", name: "YouTube Music", symbol: "play.rectangle.fill", color: 0xFF0033, link: "youtubemusic://", store: "https://apps.apple.com/app/youtube-music/id1017492454"),
        MusicTarget(id: "deezer", name: "Deezer", symbol: "waveform", color: 0xEF6C00, link: "deezer://", store: "https://apps.apple.com/app/deezer/id602231273"),
        MusicTarget(id: "tidal", name: "Tidal", symbol: "hifispeaker.fill", color: 0x111111, link: "tidal://", store: "https://apps.apple.com/app/tidal/id913943275"),
        MusicTarget(id: "soundcloud", name: "SoundCloud", symbol: "cloud.fill", color: 0xFF5500, link: "soundcloud://", store: "https://apps.apple.com/app/soundcloud/id336353151"),
        MusicTarget(id: "amazon", name: "Amazon Music", symbol: "music.mic", color: 0x25D1DA, link: "amazonmusic://", store: "https://apps.apple.com/app/amazon-music/id510855668"),
        MusicTarget(id: "qobuz", name: "Qobuz", symbol: "opticaldisc.fill", color: 0x0D47A1, link: "qobuz://", store: "https://apps.apple.com/app/qobuz/id946166469"),
    ]

    static func normalize(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if !t.contains("://") {
            t = t.contains(".") ? "https://\(t)" : "\(t)://"
        }
        guard let url = URL(string: t), let scheme = url.scheme, !scheme.isEmpty else { return nil }
        return t
    }

    static func connected(_ s: AppSettings) -> [MusicTarget] {
        let on = s.musicEnabled.isEmpty ? ["apple"] : s.musicEnabled
        let list = builtins.filter { on.contains($0.id) }
        let base = list.isEmpty ? [builtins[0]] : list
        let extras = s.musicExtras.map {
            MusicTarget(id: $0.id, name: $0.name, symbol: "link", color: 0x0891B2, link: $0.link, store: nil)
        }
        return base + extras
    }

    static func active(_ s: AppSettings) -> MusicTarget {
        let all = connected(s)
        return all.first { $0.id == s.musicActive } ?? all[0]
    }

    /// Opens the service. If that app is missing, falls through to its App Store page.
    static func open(_ t: MusicTarget) {
        guard let url = URL(string: t.link) else { return }
        let store = t.store
        UIApplication.shared.open(url, options: [:]) { ok in
            guard !ok, let store, let page = URL(string: store) else { return }
            DispatchQueue.main.async { UIApplication.shared.open(page) }
        }
    }
}

/** Tiny Liquid Glass square under the fuel price. Tap opens the player. */
struct MusicPip: View {
    @ObservedObject var music: NowPlay
    @ObservedObject private var settings = AppSettings.shared
    var open: () -> Void
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 14, style: .continuous) }

    var body: some View {
        let active = MusicCatalog.active(settings)
        Button(action: open) {
            ZStack {
                if active.isApple, let img = music.art {
                    Image(uiImage: img)
                        .resizable().scaledToFill()
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                } else {
                    Image(systemName: active.isApple ? (music.playing ? "waveform" : "music.note") : active.symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.primary)
                }
            }
            .frame(width: 46, height: 46)
            .glassButton(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(active.name)
        .onAppear { music.attach() }
    }
}

/** Dims the map and shows the rounded-square player. Tap outside closes it. */
struct MusicPlayerOverlay: View {
    @ObservedObject var music: NowPlay
    @Binding var shown: Bool

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width - 36, geo.size.height * 0.70, 420)
            ZStack {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { shut() }
                NowPlayingCard(music: music, side: side, close: shut)
            }
        }
        .ignoresSafeArea()
    }

    private func shut() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { shown = false }
    }
}

/** Square player with rounded corners, Liquid Glass, opened from the little button. */
struct NowPlayingCard: View {
    @ObservedObject var music: NowPlay
    @ObservedObject private var settings = AppSettings.shared
    var side: CGFloat
    var close: () -> Void
    @State private var showLyrics = false
    @State private var showQueue = false
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 28, style: .continuous) }
    private var artShape: RoundedRectangle { RoundedRectangle(cornerRadius: 20, style: .continuous) }
    private var active: MusicTarget { MusicCatalog.active(settings) }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 2) {
                icon("xmark", close)
                Spacer(minLength: 0)
                AirPlayButton().frame(width: 36, height: 36)
                if active.isApple {
                    icon("quote.bubble") { showLyrics = true }
                    icon("list.bullet") { showQueue = true }
                }
            }
            .frame(height: 36)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(MusicCatalog.connected(settings)) { item in
                        Button {
                            settings.musicActive = item.id
                            if !item.isApple { MusicCatalog.open(item) }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: item.symbol).font(.system(size: 11, weight: .bold))
                                Text(item.name).font(.system(size: 12, weight: .bold)).lineLimit(1)
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 26)
                            .foregroundColor(.primary)
                            .background(Capsule().fill(Color.primary.opacity(item.id == active.id ? 0.16 : 0.06)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 28)

            art
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .layoutPriority(-1)
                .clipShape(artShape)

            Text(headline)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(subtitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if active.isApple {
                Slider(value: $music.elapsed, in: 0...max(music.duration, 1), onEditingChanged: { editing in
                    music.scrubbing = editing
                    if !editing { music.seek(music.elapsed) }
                })
                .tint(.primary)
                .disabled(!music.allowed || music.duration <= 0)

                HStack(spacing: 18) {
                    jump("backward.fill") { music.previous() }
                    Button { music.toggle() } label: {
                        Image(systemName: music.playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.primary)
                            .frame(width: 54, height: 54)
                            .glassButton(Circle())
                    }
                    .buttonStyle(.plain)
                    jump("forward.fill") { music.next() }
                }

                if !music.allowed {
                    Button { music.attach() } label: {
                        Text("Pozwól na dostęp do Muzyki")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Color(hex: 0x0F766E))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Button { MusicCatalog.open(active) } label: {
                    Label("Otwórz \(active.name)", systemImage: "arrow.up.forward.app")
                        .font(.system(size: 15, weight: .bold))
                        .lineLimit(1)
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .glassButton(Capsule())
                }
                .buttonStyle(.plain)
                Text("Pauza jest w tej aplikacji. Apex może ją tylko otworzyć.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(14)
        .frame(width: side, height: side)
        .glass(shape)
        .clipShape(shape)
        .onAppear { music.attach() }
        .sheet(isPresented: $showLyrics) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Tekst").font(.system(size: 22, weight: .bold))
                ScrollView {
                    Text(music.lyrics.isEmpty ? "Brak tekstu w Muzyce dla tego utworu." : music.lyrics)
                        .font(.system(size: 17))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showQueue) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Kolejka").font(.system(size: 22, weight: .bold))
                if music.title.isEmpty {
                    Text("Nic nie jest w kolejce. Włącz album albo playlistę w Muzyce.")
                        .foregroundColor(.secondary)
                } else {
                    HStack(spacing: 12) {
                        Image(systemName: "music.note").frame(width: 36, height: 36)
                        VStack(alignment: .leading) {
                            Text(music.title).font(.headline)
                            Text(music.artist.isEmpty ? "Teraz gra" : music.artist).font(.subheadline).foregroundColor(.secondary)
                        }
                    }
                    Text("Reszty kolejki Apple nie oddaje innym aplikacjom. Poprzedni i następny i tak przeskakują utwory w Muzyce.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(20)
            .presentationDetents([.medium])
        }
    }

    private var headline: String {
        if !active.isApple { return active.name }
        return music.title.isEmpty ? "Nic nie gra" : music.title
    }

    private var subtitle: String {
        if !active.isApple { return "Połączone. Stuknij, żeby otworzyć." }
        if music.title.isEmpty { return "Włącz utwór w Muzyce" }
        return music.artist.isEmpty ? "Muzyka" : music.artist
    }

    private var art: some View {
        Group {
            if active.isApple, let img = music.art {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                Image(systemName: active.isApple ? "music.note" : active.symbol)
                    .font(.system(size: 42, weight: .bold))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.primary.opacity(0.06))
            }
        }
    }

    private func icon(_ name: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.primary)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
    }

    private func jump(_ name: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.primary)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Compass calibration (the location button)

struct CalibrateSheet: View {
    @ObservedObject var location: LocationService
    @Environment(\.dismiss) private var dismiss
    @State private var cheered = false

    private var heading: Double {
        guard let h = location.heading else { return 0 }
        return h.trueHeading >= 0 ? h.trueHeading : h.magneticHeading
    }

    private enum Grade { case low, mid, high }

    private var grade: Grade {
        guard let h = location.heading, h.headingAccuracy >= 0 else { return .low }
        if h.headingAccuracy <= 12 { return .high }
        if h.headingAccuracy <= 25 { return .mid }
        return .low
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Skalibruj")
                .font(.system(size: 20, weight: .semibold))
                .padding(.top, 18)

            Spacer(minLength: 8)

            ZStack {
                Circle().stroke(Color.white.opacity(0.18), lineWidth: 1)
                ForEach(0..<72, id: \.self) { i in
                    Rectangle()
                        .fill(Color.white.opacity(i % 18 == 0 ? 0.95 : 0.35))
                        .frame(width: i % 6 == 0 ? 2 : 1, height: i % 6 == 0 ? 16 : 8)
                        .offset(y: -118)
                        .rotationEffect(.degrees(Double(i) * 5))
                }
                compassLetter("N", .red).offset(y: -148)
                compassLetter("E", .white).offset(x: 148)
                compassLetter("S", .white).offset(y: 148)
                compassLetter("W", .white).offset(x: -148)
                needle.rotationEffect(.degrees(heading))
                Circle().fill(Color.white).frame(width: 10, height: 10)
            }
            .frame(width: 300, height: 300)
            .padding(.bottom, 8)

            FigureEight()
                .stroke(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: 72, height: 36)
                .padding(.bottom, 14)

            Text("Rysuj ósemkę")
                .font(.system(size: 28, weight: .bold))
            Text("Obróć iPhone'a, aby skalibrować kompas")
                .font(.system(size: 16))
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.top, 6)

            if let loc = location.last, loc.horizontalAccuracy > 0 {
                Text(loc.horizontalAccuracy < 20
                     ? String(format: "GPS ± %.0f m", loc.horizontalAccuracy)
                     : String(format: "GPS ± %.0f m — wyjdź spod dachu, jeśli kropka ucieka", loc.horizontalAccuracy))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                    .padding(.top, 8)
            }

            HStack(spacing: 28) {
                gradeDot("Niska", .red, grade == .low)
                gradeDot("Średnia", Color(hex: 0xF5A524), grade == .mid)
                gradeDot("Wysoka", Color(hex: 0x34C759), grade == .high)
            }
            .padding(.top, 26)

            Spacer()

            HStack {
                Button("Anuluj") { dismiss() }
                    .font(.system(size: 17))
                    .foregroundColor(.white.opacity(0.85))
                Spacer()
                Button("Gotowe") { dismiss() }
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(grade == .low ? Color(hex: 0x0A84FF).opacity(0.45) : Color(hex: 0x0A84FF))
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .foregroundColor(.white)
        .preferredColorScheme(.dark)
        .onAppear { location.setHeading(true) }
        .onDisappear { location.setHeading(false) }
        .onChange(of: grade == .high) { high in
            if high, !cheered {
                cheered = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
    }

    private var needle: some View {
        VStack(spacing: 0) {
            NeedleHalf(up: true).fill(Color.red).frame(width: 16, height: 108)
            NeedleHalf(up: false).fill(Color.white).frame(width: 16, height: 108)
        }
    }

    private func compassLetter(_ t: String, _ color: Color) -> some View {
        Text(t).font(.system(size: 20, weight: .bold)).foregroundColor(color)
    }

    private func gradeDot(_ title: String, _ color: Color, _ on: Bool) -> some View {
        VStack(spacing: 6) {
            Circle().fill(on ? color : color.opacity(0.35)).frame(width: 8, height: 8)
            Text(title)
                .font(.system(size: 13, weight: on ? .bold : .regular))
                .foregroundColor(on ? .white : .white.opacity(0.4))
        }
    }
}

/** Red/white compass needle, tip at the top when `up` is the north half. */
private struct NeedleHalf: Shape {
    var up: Bool
    func path(in r: CGRect) -> Path {
        var p = Path()
        if up {
            p.move(to: CGPoint(x: r.midX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        } else {
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        }
        p.closeSubpath()
        return p
    }
}

private struct FigureEight: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.addEllipse(in: CGRect(x: r.minX, y: r.midY - r.height * 0.28, width: r.width * 0.52, height: r.height * 0.56))
        p.addEllipse(in: CGRect(x: r.midX - r.width * 0.02, y: r.midY - r.height * 0.28, width: r.width * 0.52, height: r.height * 0.56))
        return p
    }
}
