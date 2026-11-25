import Foundation

/**
 * Road names the way they should be said. Google and OpenStreetMap shorten them for the screen
 * ("Stoneham Wy.", "Burgess Rd", "So'ton"), and the phone's voice reads those letter by letter
 * or not at all.
 */
public enum SpokenText {
    /** Whole words only, so "Rd" in "Rd." goes but "Rdg" or "Ford" stay. */
    static let words: [(String, String)] = [
        ("Rd", "Road"), ("Wy", "Way"), ("Ln", "Lane"), ("Ave", "Avenue"), ("Av", "Avenue"),
        ("Dr", "Drive"), ("Pl", "Place"), ("Cres", "Crescent"), ("Cl", "Close"), ("Gdns", "Gardens"),
        ("Sq", "Square"), ("Hwy", "Highway"), ("Pkwy", "Parkway"), ("Blvd", "Boulevard"), ("Ct", "Court"),
        ("Gr", "Grove"), ("Tce", "Terrace"), ("Terr", "Terrace"), ("Rdbt", "roundabout"), ("Rbt", "roundabout"),
        ("Jct", "junction"), ("Nr", "near"), ("Ctr", "Centre"), ("Ind Est", "Industrial Estate"),
        ("So'ton", "Southampton"), ("Soton", "Southampton"), ("Pompey", "Portsmouth"),
    ]

    public static func forVoice(_ text: String) -> String {
        var s = text
        for (short, long) in words {
            // The short form as a word of its own; a full stop after it stays, as a pause.
            let pattern = "(?<![\\p{L}'])" + NSRegularExpression.escapedPattern(for: short) + "(?![\\p{L}'])"
            s = s.replacingOccurrences(of: pattern, with: long, options: .regularExpression)
        }
        // "St" is Street after a name ("Princes St") but Saint before one ("onto St Mary's Road",
        // "At St Mary's Roundabout": a capital word in front isn't enough when a name follows).
        s = s.replacingOccurrences(of: "(?<=\\p{Lu}[\\p{L}']{1,30} )St(?![\\p{L}'])(?! \\p{Lu})", with: "Street", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?<![\\p{L}'])St\\.?(?= \\p{Lu})", with: "Saint", options: .regularExpression)
        // "A57(M)" is said "A57 M".
        s = s.replacingOccurrences(of: "(?<=\\d)\\(M\\)", with: " M", options: .regularExpression)
        // "A14", "B1", "K1163" as a letter and the number, not one mashed word.
        s = s.replacingOccurrences(of: "(?<![\\p{L}\\d])([ABKL])\\s?(\\d{1,4})(?![\\p{L}\\d])", with: "$1 $2", options: .regularExpression)
        // "N", "S", "E", "W" after a road number: "A33 N" is "A33 north".
        for (d, w) in [("N", "north"), ("S", "south"), ("E", "east"), ("W", "west")] {
            s = s.replacingOccurrences(of: "(?<=\\d) \(d)(?![\\p{L}'])", with: " \(w)", options: .regularExpression)
        }
        // A Polish (or English) voice stumbles on German endings, and a second sentence
        // ("ulica") sounds like the line was cut. Say the ending in place, once.
        if AppSettings.shared.language != "de" {
            let folds = [("ä", "e"), ("ö", "o"), ("ü", "u"), ("Ä", "E"), ("Ö", "O"), ("Ü", "U"), ("ß", "s")]
            for (a, b) in folds { s = s.replacingOccurrences(of: a, with: b) }
            s = s.replacingOccurrences(of: "strasse", with: " sztrase", options: .caseInsensitive)
            s = s.replacingOccurrences(of: "(?<=\\p{L})Str\\.", with: " sztrase", options: .regularExpression)
            s = s.replacingOccurrences(of: "(?<![\\p{L}])Str\\.", with: "sztrase", options: .regularExpression)
            s = s.replacingOccurrences(of: "(?<![\\p{L}])Str(?![\\p{L}\\d])", with: "sztrase", options: .regularExpression)
            s = s.replacingOccurrences(of: "platz", with: " plac", options: .caseInsensitive)
            s = s.replacingOccurrences(of: "gasse", with: " gase", options: .caseInsensitive)
            s = s.replacingOccurrences(of: "chaussee", with: " szose", options: .caseInsensitive)
            s = s.replacingOccurrences(of: "allee", with: " alee", options: .caseInsensitive)
            s = s.replacingOccurrences(of: "(?<![\\p{L}])Weg(?![\\p{L}])", with: "wek", options: .regularExpression)
            s = s.replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
            s = s.replacingOccurrences(of: " na (?=\\p{Lu})", with: " na, ", options: .regularExpression)
        }
        return s.trimmingCharacters(in: .whitespaces)
    }
}
