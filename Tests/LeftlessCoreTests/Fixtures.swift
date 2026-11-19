import Foundation

/// Sahte kök dizin: her örnek benzersiz bir geçici kök oluşturur.
struct FakeSystem {
    let root: URL
    var home: URL { root.appendingPathComponent("Users/tester", isDirectory: true) }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("leftless-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    /// `<dir>/<name>.app/Contents/Info.plist` (+ `Contents/MacOS/<executable>`) üretir. `dir` verilmezse root/Applications.
    @discardableResult
    func makeApp(name: String, bundleID: String, executable: String? = nil,
                 version: String? = "1.0", in dir: URL? = nil) throws -> URL {
        let parent = dir ?? root.appendingPathComponent("Applications", isDirectory: true)
        let app = parent.appendingPathComponent("\(name).app", isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let exe = executable ?? name
        var plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": name,
            "CFBundleExecutable": exe,
        ]
        if let version { plist["CFBundleShortVersionString"] = version }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data(count: 10).write(to: macOS.appendingPathComponent(exe))
        return app
    }

    /// root + relative yolunda dosya üretir (üst klasörlerle).
    @discardableResult
    func touch(_ relative: String, bytes: Int = 10) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
        return url
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
