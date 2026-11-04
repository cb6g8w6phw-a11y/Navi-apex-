import Foundation

extension String {
    /// Tłumaczenie klucza z Localizable.strings
    var localized: String { NSLocalizedString(self, comment: "") }
}
