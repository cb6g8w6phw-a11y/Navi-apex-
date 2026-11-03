import Foundation

/// Minimal stub used for screenshot/demo automation.
///
/// The production app does not currently use this automation flow, but the codebase
/// references it in several views. Keeping the API as a no-op avoids breaking the
/// app while preserving the compile-time contract expected by those views.
enum DemoScript {
    static let active = false
    static let fakeWaze = false
    static let step: String? = nil
    static let wazeProbe = ""
    static let scrollResults = Notification.Name("DemoScript.scrollResults")

    static func run(_ model: AppModel) async {
        // Intentionally left blank: no automated demo flow is active in normal builds.
    }
}
