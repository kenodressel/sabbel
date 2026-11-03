import SabbelCore

/// What the live panel renders for a take's live text.
public enum LiveDisplay {
    /// The settled text (shown in the primary colour) and the provisional text
    /// (secondary), with one space between them.
    ///
    /// A take that started in a password field never shows its words: only
    /// "•••" once something was heard, and nothing before that.
    public static func parts(_ text: LiveText, masked: Bool) -> (settled: String, provisional: String) {
        if masked {
            return text.settled.isEmpty && text.provisional.isEmpty ? ("", "") : ("•••", "")
        }
        let gap = !text.settled.isEmpty && !text.provisional.isEmpty ? " " : ""
        return (text.settled, gap + text.provisional)
    }
}
