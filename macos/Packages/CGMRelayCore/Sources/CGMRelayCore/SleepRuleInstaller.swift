import Foundation

/// SleepRuleInstaller builds exactly what the one administrator prompt
/// installs: a sudoers rule that lets this user run two commands, and a
/// boot-time job that turns the setting off again after every restart. It
/// only builds text. Running the scripts is SleepRuleAdministrator's job.
public enum SleepRuleInstaller {
    public static let sudoersPath = "/etc/sudoers.d/cgm-relay-disablesleep"
    public static let bootResetPlistPath = "/Library/LaunchDaemons/com.yaanfpv.cgmrelay.sleep-reset.plist"
    public static let bootResetLabel = "com.yaanfpv.cgmrelay.sleep-reset"

    private static let sleepOff = "/usr/bin/pmset -a disablesleep 0"
    private static let sleepOn = "/usr/bin/pmset -a disablesleep 1"

    /// sudoersRule is the whole rule file: a comment, then one line that
    /// allows these two commands for user and nothing else.
    public static func sudoersRule(user: String) -> String {
        """
        # Installed by CGM Relay. Lets this user turn the Mac's sleep setting on and off, and nothing else.
        \(user) ALL=(root) NOPASSWD: \(sleepOff), \(sleepOn)

        """
    }

    /// bootResetPlist is the LaunchDaemon that turns the setting off once
    /// at every boot.
    public static func bootResetPlist() -> Data {
        let plist: [String: Any] = [
            "Label": bootResetLabel,
            "ProgramArguments": ["/usr/bin/pmset", "-a", "disablesleep", "0"],
            "RunAtLoad": true,
        ]
        // Serializing a fixed dictionary of strings and a boolean cannot fail.
        return (try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)) ?? Data()
    }

    /// installScript is the shell script that runs as root: it stages both
    /// files in a private temporary path, has visudo check the rule there,
    /// and only then moves the two files into place. Any failure stops the
    /// script before anything is moved.
    public static func installScript(user: String) -> String {
        let ruleLines = sudoersRule(user: user)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { shellQuoted(String($0)) }
            .joined(separator: " ")
        let plist = String(decoding: bootResetPlist(), as: UTF8.self)
        return """
        set -e
        umask 077
        STAGED_RULE=$(/usr/bin/mktemp /private/tmp/cgm-relay-rule.XXXXXX)
        STAGED_PLIST=$(/usr/bin/mktemp /private/tmp/cgm-relay-plist.XXXXXX)
        trap '/bin/rm -f "$STAGED_RULE" "$STAGED_PLIST"' EXIT
        /usr/bin/printf '%s\\n' \(ruleLines) > "$STAGED_RULE"
        /usr/sbin/visudo -c -q -f "$STAGED_RULE"
        /usr/bin/printf '%s' \(shellQuoted(plist)) > "$STAGED_PLIST"
        /usr/bin/plutil -lint "$STAGED_PLIST" > /dev/null
        /usr/sbin/chown root:wheel "$STAGED_RULE"
        /usr/sbin/chown root:wheel "$STAGED_PLIST"
        /bin/chmod 440 "$STAGED_RULE"
        /bin/chmod 644 "$STAGED_PLIST"
        /bin/mv "$STAGED_RULE" \(shellQuoted(sudoersPath))
        /bin/mv "$STAGED_PLIST" \(shellQuoted(bootResetPlistPath))
        """
    }

    /// removeScript puts the setting back first, then removes both files.
    public static func removeScript() -> String {
        """
        set -e
        \(sleepOff)
        /bin/rm -f \(shellQuoted(sudoersPath))
        /bin/rm -f \(shellQuoted(bootResetPlistPath))
        """
    }

    /// isSafeUserName is whether name can go into the rule as it is: the
    /// letters, digits and dot, dash and underscore of an ordinary account
    /// name, never starting with a dash.
    public static func isSafeUserName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first != "-" else { return false }
        return name.unicodeScalars.allSatisfy {
            ($0.value < 128) && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0))
        }
    }

    private static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
