import Foundation
import Network

/** Whether the phone has an internet connection, so a failed search or route can say why. */
@MainActor
final class Connectivity: ObservableObject {
    static let shared = Connectivity()
    @Published private(set) var online = true
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { path in
            let ok = path.status == .satisfied
            Task { @MainActor in Connectivity.shared.online = ok }
        }
        monitor.start(queue: DispatchQueue(label: "kite.connectivity"))
    }

    /** "No internet connection." when offline, else [fallback]. */
    static func explain(_ fallback: String) -> String {
        shared.online ? fallback : "No internet connection. Check your signal and try again."
    }
}
