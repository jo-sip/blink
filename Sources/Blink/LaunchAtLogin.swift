import Foundation
import ServiceManagement

/// Starts Blink when you log in (System Settings → General → Login Items lists it).
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Only the copy in /Applications registers, so test builds never add themselves.
    static func apply(_ wanted: Bool) {
        guard Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        let service = SMAppService.mainApp
        do {
            if wanted, service.status != .enabled {
                try service.register()
                Log.write("launch at login: on")
            } else if !wanted, service.status == .enabled {
                try service.unregister()
                Log.write("launch at login: off")
            }
        } catch {
            Log.write("launch at login: could not change (\(error.localizedDescription))")
        }
    }
}
