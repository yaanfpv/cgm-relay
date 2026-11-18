import Foundation

/// ThrowawaySuite is a UserDefaults suite of a test's own, named by a path in
/// a temporary folder so its preferences file is written there rather than in
/// ~/Library/Preferences. remove() clears the suite and deletes the folder.
struct ThrowawaySuite {
    let name: String
    let defaults: UserDefaults
    private let folder: URL

    init() {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("cgmrelay-suite-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        name = folder.appendingPathComponent("cgmrelay.tests").path
        defaults = UserDefaults(suiteName: name)!
    }

    func remove() {
        defaults.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(at: folder)
    }
}
