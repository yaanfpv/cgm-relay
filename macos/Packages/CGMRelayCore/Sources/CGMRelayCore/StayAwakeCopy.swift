/// StayAwakeCopy is what setup and Settings say about keeping this Mac
/// awake, so the two always agree.
public enum StayAwakeCopy {
    public static let title = "Keep this Mac awake"

    /// explanation says what staying awake does on this kind of Mac, and
    /// what happens when it can't.
    public static func explanation(isLaptop: Bool) -> String {
        if isLaptop {
            return "This Mac stays awake, with the lid closed too, only while it is plugged in. On battery it sleeps as usual, and CGM Relay keeps the 15-minute history but loses the minute readings from the time it sleeps. Turning this on asks for your Mac's password once, so CGM Relay can change only the sleep setting, and for your approval of a background item in System Settings, so the Mac can sleep again if CGM Relay ever ends unexpectedly."
        }
        return "This Mac won't sleep while CGM Relay runs, so no minute is lost."
    }

    /// permissionNote is what Settings says about the permission once it
    /// has been given.
    public static let permissionNote = "The permission to change the sleep setting stays on this Mac once it is granted, so turning this off and on again never asks for it again."
}
