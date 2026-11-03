/// Per-app output rules. First rule: chat, terminal and IDE apps get the
/// dictation without its trailing full stop, because messages and prompts
/// don't end with "." there.
public enum AppRules {
    /// Bundle IDs the rule applies to. An entry ending in `.*` matches every
    /// bundle ID with that prefix; anything else must match exactly.
    /// Add an app here to extend the rule.
    public static let noTrailingPeriodApps: [String] = [
        // Chat
        "com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.microsoft.teams2",
        "com.microsoft.teams", "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram",
        "org.whispersystems.signal-desktop", "com.apple.MobileSMS",
        // Terminals
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "org.alacritty",
        "com.github.wez.wezterm",
        // IDEs and editors with chat panes
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed",
        "com.jetbrains.*", "com.apple.dt.Xcode", "com.exafunction.windsurf",
    ]

    /// Words whose final period belongs to them (compared lowercased).
    static let periodAbbreviations: Set<String> = [
        "usw.", "bzw.", "etc.", "ca.", "vgl.", "ggf.", "evtl.", "inkl.",
        "nr.", "dr.", "hr.", "fr.",
    ]

    static func matches(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return noTrailingPeriodApps.contains { entry in
            entry.hasSuffix(".*") ? bundleID.hasPrefix(String(entry.dropLast())) : bundleID == entry
        }
    }

    /// Removes one trailing "." unless it ends an ellipsis or an abbreviation.
    /// Trailing whitespace is preserved.
    static func dropTrailingPeriod(_ text: String) -> String {
        guard let end = text.lastIndex(where: { !$0.isWhitespace }), text[end] == "." else { return text }
        let body = text[..<end]
        if body.last == "." { return text }  // "..."
        let word = text[..<text.index(after: end)]
            .split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? "."
        if isAbbreviation(word) { return text }
        var result = text
        result.remove(at: end)
        return result
    }

    /// "B.", "e.g.", "i.e.", "usw." ... (a word ending in its period).
    private static func isAbbreviation(_ word: String) -> Bool {
        if periodAbbreviations.contains(word.lowercased()) { return true }
        // One or more single letters, each followed by a period.
        let parts = word.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.last == ""
            && parts.dropLast().allSatisfy { $0.count == 1 && $0.first!.isLetter }
    }

    /// The pipeline stage.
    public static func stage(_ text: String, _ target: FocusTarget?) -> String {
        matches(bundleID: target?.bundleID) ? dropTrailingPeriod(text) : text
    }
}
