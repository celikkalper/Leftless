import AppKit

enum FullDiskAccess {
    /// Yalnızca Tam Disk Erişimi ile okunabilen iki konumdan biri okunabiliyorsa izin verilmiştir.
    static func isGranted() -> Bool {
        let fm = FileManager.default
        let stocks = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers/com.apple.stocks")
        if (try? fm.contentsOfDirectory(atPath: stocks.path)) != nil { return true }
        let tcc = "/Library/Application Support/com.apple.TCC/TCC.db"
        if let handle = FileHandle(forReadingAtPath: tcc) {
            try? handle.close()
            return true
        }
        return false
    }

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }
}
