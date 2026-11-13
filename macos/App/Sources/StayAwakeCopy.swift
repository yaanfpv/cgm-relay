/// StayAwakeCopy is what setup and Settings say about keeping this Mac
/// awake, so the two always agree.
enum StayAwakeCopy {
    static let title = "Keep this Mac awake"

    /// explanation says what staying awake does on this kind of Mac, and
    /// what happens when it can't.
    static func explanation(isLaptop: Bool) -> String {
        if isLaptop {
            return "This Mac stays awake, with the lid closed too, only while it is plugged in. On battery it sleeps as usual, and CGM Relay keeps the 15-minute history but loses the minute readings from the time it sleeps. Turning this on asks for your Mac's password once, so CGM Relay can change only the sleep setting."
        }
        return "This Mac won't sleep while CGM Relay runs, so no minute is lost."
    }

    static let removeDialogTitle = "Remove the Sleep Permission?"
    static let removeDialogMessage = "CGM Relay was allowed to change this Mac's sleep setting. You can take that permission away too. Your Mac asks for its password to do it."
}
