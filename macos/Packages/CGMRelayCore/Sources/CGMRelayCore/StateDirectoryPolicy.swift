import Foundation

/// StateDirectoryPolicy prepares the folder the built-in Tailscale node keeps
/// its sign-in key in: private to this person and left out of Time Machine
/// backups. The exclusion stays with the folder, so a folder created again
/// after leaving the route gets it again each time this runs.
public enum StateDirectoryPolicy {
    /// prepare creates the folder when it is missing, sets its mode to 0700
    /// and marks it excluded from backups. What the folder already holds is
    /// kept. A path that is a file throws.
    public static func prepare(at directory: URL) throws {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: directory.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            throw CocoaError(.fileWriteFileExists)
        }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
    }
}
