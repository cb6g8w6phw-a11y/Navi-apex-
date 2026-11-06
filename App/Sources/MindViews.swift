import SwiftUI

/** One quiet line from the driving mind: fuel, a border, a green wave, a tunnel. */
struct MindNoteCard: View {
    var note: GuidanceNote

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(note.title).font(.system(size: 15, weight: .semibold))
                Text(note.body).font(.system(size: 13)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var color: Color {
        switch note.tone {
        case "warn": return Color(hex: 0xF59E0B)
        case "good": return Color(hex: 0x14B8A6)
        default: return Color(hex: 0x38BDF8)
        }
    }
}

/** One short line: city and the green sticker, only while the trip still has to enter the zone. */
struct UmweltChip: View {
    var name: String
    /// The car has no sticker, so this zone is a wall, not a warning.
    var blocked = false

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(blocked ? Color(hex: 0xDC2626) : Color(hex: 0x22C55E)).frame(width: 8, height: 8)
            Text(blocked ? "Bez plakietki" : "Wymagana").font(.system(size: 13, weight: .bold))
            Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }
}
