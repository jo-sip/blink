import Foundation

/// Plain-text log at ~/Library/Logs/Blink.log (open it from the menu bar icon).
/// It records what Blink did, never message text or what you typed.
enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Blink.log")
    private static let lock = NSLock()
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "\(stamp.string(from: Date())) \(message)\n"
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 1_000_000 {
            try? fm.removeItem(at: url)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    /// Records Objective-C exceptions before the process dies; macOS writes the crash report itself
    /// to ~/Library/Logs/DiagnosticReports.
    static func installCrashHandler() {
        NSSetUncaughtExceptionHandler { e in
            Log.write("CRASH uncaught exception \(e.name.rawValue): \(e.reason ?? "")\n\(e.callStackSymbols.prefix(15).joined(separator: "\n"))")
        }
    }
}

/// True when Spotlight's own ⌘Space shortcut is switched on; it then gets the key before Blink.
func spotlightUsesCmdSpace() -> Bool {
    guard let all = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys"),
          let entry = all["64"] as? [String: Any] else { return false }
    if let b = entry["enabled"] as? Bool { return b }
    return (entry["enabled"] as? Int) == 1
}
