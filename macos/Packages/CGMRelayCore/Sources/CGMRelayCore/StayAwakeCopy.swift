/// StayAwakeCopy is what setup and Settings say about keeping this Mac
/// awake, so the two always agree. Each string is one or two short
/// sentences.
public enum StayAwakeCopy {
    public static let title = "Keep this Mac awake"

    /// explanation says what staying awake does on this kind of Mac: a
    /// laptop stays awake only while plugged in and sleeps on battery.
    public static func explanation(isLaptop: Bool) -> String {
        if isLaptop {
            return "Stays awake while plugged in, even with the lid closed. On battery it sleeps as usual."
        }
        return "This Mac won't sleep while CGM Relay runs."
    }

    /// permissionNote is the password line: turning this on on a laptop asks
    /// for the Mac's password to set up the permission. Settings and the
    /// setup step show it after the explanation.
    public static let permissionNote = "Asks for your password to set this up."

    /// approvalNeeded says why the helper still needs the person's approval:
    /// without it the Mac cannot go back to sleeping after a crash.
    public static let approvalNeeded = "Allow CGM Relay in Login Items so this Mac can sleep after a crash."
    public static let openLoginItems = "Open Login Items"
}
