#if DEBUG
import AppKit
import LeftlessCore
import SwiftUI

/// Renders README screenshots from fictional demo data (Debug builds only):
/// `Leftless --screenshots <output-dir>` writes apps.png, apps-dark.png and history.png, then quits.
/// Nothing is read from the real disk or history, so no personal data ends up in the images.
@MainActor
enum Screenshots {
    static func runIfRequested() -> Bool {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--screenshots"), index + 1 < args.count else { return false }
        let dir = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        Task { @MainActor in
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let shots: [(String, MainTab, Bool, CGFloat)] = [("apps", .apps, false, 660), ("apps-dark", .apps, true, 660),
                                                             ("history", .history, false, 330)]
            for (name, tab, dark, height) in shots {
                let model = DemoData.model()
                model.tab = tab
                await capture(ContentView(model: model), height: height, dark: dark,
                              to: dir.appending(path: "\(name).png"))
            }
            NSApp.terminate(nil)
        }
        return true
    }

    private static func capture(_ view: ContentView, height: CGFloat, dark: Bool, to url: URL) async {
        let size = NSSize(width: 1080, height: height)
        let hosting = NSHostingController(rootView: view.frame(width: size.width, height: size.height))
        hosting.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.title = "Leftless"
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setContentSize(size)
        window.center()
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .seconds(2))
        guard let frameView = window.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.close()
    }
}

/// Fictional apps, leftovers and history used only for screenshots.
@MainActor
enum DemoData {
    /// Fake files live in a throwaway temp folder so Finder icons (folders, plists, app icons) look real.
    private static let root = FileManager.default.temporaryDirectory.appending(path: "leftless-demo").path
    private static let home = root + "/Users/demo"
    private static let mb: Int64 = 1_000_000
    private static var icons: [String: NSImage] = [:]

    /// A rounded-square app icon with a white SF Symbol, in the given colour.
    private static func makeIcon(_ symbol: String, _ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
            let body = rect.insetBy(dx: 50, dy: 50)
            color.setFill()
            NSBezierPath(roundedRect: body, xRadius: 112, yRadius: 112).fill()
            let config = NSImage.SymbolConfiguration(pointSize: 220, weight: .semibold)
                .applying(.init(paletteColors: [.white]))
            if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                let s = glyph.size
                glyph.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2,
                                      width: s.width, height: s.height))
            }
            return true
        }
    }

    private static func touch(_ path: String, directory: Bool) {
        let fm = FileManager.default
        if directory {
            try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        } else {
            try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                    withIntermediateDirectories: true)
            fm.createFile(atPath: path, contents: Data())
        }
    }

    private static func app(_ name: String, _ id: String, _ size: Int64, _ version: String,
                            _ symbol: String, _ color: NSColor) -> InstalledApp {
        let path = "\(root)/Applications/\(name).app"
        touch(path + "/Contents", directory: true)
        let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundlePackageType": "APPL"]
        (plist as NSDictionary).write(toFile: path + "/Contents/Info.plist", atomically: true)
        let icon = makeIcon(symbol, color)
        icons[name] = icon
        NSWorkspace.shared.setIcon(icon, forFile: path, options: [])
        return InstalledApp(info: AppInfo(url: URL(fileURLWithPath: path), bundleID: id, name: name,
                                          version: version),
                            bundleSize: size)
    }

    private static func pngData(_ image: NSImage?) -> Data? {
        guard let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    static func model() -> AppModel {
        try? FileManager.default.removeItem(atPath: root)
        let apps = [
            app("CodePad", "com.example.codepad", 640 * mb, "3.2", "chevron.left.forwardslash.chevron.right", .systemIndigo),
            app("Notely", "com.example.notely", 182 * mb, "5.0.1", "note.text", .systemYellow),
            app("PixelForge", "com.example.pixelforge", 1_240 * mb, "2.8", "paintbrush.pointed.fill", .systemPink),
            app("SoundWave", "com.example.soundwave", 380 * mb, "1.2.4", "waveform", .systemOrange),
            app("Streamline", "com.example.streamline", 230 * mb, "4.1", "play.rectangle.fill", .systemRed),
            app("Tasky", "com.example.tasky", 96 * mb, "7.3", "checklist", .systemGreen),
            app("Weatherly", "com.example.weatherly", 58 * mb, "2.0", "cloud.sun.fill", .systemTeal)
        ]
        let selected = apps[3]
        func item(_ path: String, _ kind: LeftoverKind, _ size: Int64, _ confidence: Confidence = .certain,
                  label: String? = nil) -> Leftover {
            let isFile = [.preferences, .launchAgent].contains(kind)
            if kind != .appBundle { touch(path, directory: !isFile) }
            return Leftover(url: URL(fileURLWithPath: path), kind: kind, confidence: confidence, size: size,
                            launchdLabel: label)
        }
        let leftovers = [
            item(selected.info.url.path, .appBundle, 380 * mb),
            item("\(home)/Library/Application Support/SoundWave", .applicationSupport, 24 * mb),
            item("\(home)/Library/Caches/com.example.soundwave", .caches, 61 * mb),
            item("\(home)/Library/Caches/com.example.soundwave.ShipIt", .caches, 9 * mb),
            item("\(home)/Library/Preferences/com.example.soundwave.plist", .preferences, 4_000),
            item("\(home)/Library/Logs/SoundWave", .logs, 2 * mb),
            item("\(home)/Library/Saved Application State/com.example.soundwave.savedState", .savedState, 12_000),
            item("\(home)/Library/LaunchAgents/com.example.soundwave.helper.plist", .launchAgent, 1_000,
                 label: "com.example.soundwave.helper"),
            item("\(home)/Library/Containers/com.example.soundwave.widget", .container, 3 * mb),
            item("\(home)/Music/SoundWave", .personalFolder, 1_100 * mb, .probable)
        ]
        let scan = ScanResult(app: selected.info, leftovers: leftovers)

        let day: TimeInterval = 86_400
        icons["GameHub"] = makeIcon("gamecontroller.fill", .systemPurple)
        func record(_ name: String, _ id: String, count: Int, ago: Double) -> HistoryRecord {
            let items = (0..<count).map { i in
                HistoryItem(originalPath: "\(home)/Library/Caches/\(id).\(i)", trashPath: "\(home)/.Trash/\(id).\(i)",
                            kind: .caches, size: 12 * mb, requiresAdmin: false, state: .trashed)
            }
            return HistoryRecord(appName: name, bundleID: id, version: "1.0",
                                 date: Date().addingTimeInterval(-ago * day), icon: pngData(icons[name]),
                                 items: items)
        }
        let history = [
            record("Tasky", "com.example.tasky.old", count: 9, ago: 0.1),
            record("Weatherly", "com.example.weatherly.old", count: 6, ago: 3),
            record("Streamline", "com.example.streamline.old", count: 11, ago: 12),
            record("GameHub", "com.example.gamehub", count: 14, ago: 40)
        ]
        let status: [UUID: RestoreStatus] = [
            history[0].id: .restorable, history[1].id: .partial(missing: 1),
            history[2].id: .restored, history[3].id: .unrecoverable
        ]
        return AppModel(demoApps: apps, selection: selected, scan: scan, history: history, historyStatus: status)
    }
}
#endif
