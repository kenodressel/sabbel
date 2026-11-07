import SabbelCore

/// What the overlay renders for a take's live text.
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

    /// At most the newest `limit` characters of `parts`, from the start of a
    /// word, with a leading "…". The overlay shows two lines, and the newest
    /// words must stay in view however long the take runs.
    public static func tail(_ parts: (settled: String, provisional: String),
                            limit: Int) -> (settled: String, provisional: String) {
        let full = parts.settled + parts.provisional
        guard limit > 0, full.count > limit else { return parts }
        let cut = full.index(full.endIndex, offsetBy: -limit)
        var start = cut
        // A cut inside a word moves on to the next word; a single word longer
        // than the limit keeps the hard cut.
        if !full[full.index(before: cut)].isWhitespace,
           let space = full[cut...].firstIndex(where: \.isWhitespace) {
            start = space
        }
        start = full[start...].firstIndex(where: { !$0.isWhitespace }) ?? cut
        let kept = full.distance(from: start, to: full.endIndex)
        let provisionalKept = min(kept, parts.provisional.count)
        let settledKept = kept - provisionalKept
        let provisional = String(parts.provisional.suffix(provisionalKept))
        if settledKept > 0 { return ("…" + parts.settled.suffix(settledKept), provisional) }
        return ("", "…" + provisional.drop(while: \.isWhitespace))
    }
}
