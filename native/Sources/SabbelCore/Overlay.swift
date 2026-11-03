import Foundation

/// `[overlay] style`: how much the recording overlay shows during a take.
public enum OverlayStyle: String, CaseIterable, Equatable, Sendable {
    /// Dot, level bars and elapsed time.
    case minimal
    /// As `minimal`, plus the live text under the bar row.
    case text
    /// No overlay.
    case off
}

/// A take's life as the overlay follows it. `take` numbers the takes, so a
/// late event of an earlier take never touches the one on screen.
public enum TakeEvent: Equatable, Sendable {
    /// The hotkey went down and the mic is live.
    case started(take: Int)
    /// The hotkey came up; the take is being finished.
    case released(take: Int)
    /// Escape or a key combo dropped the take.
    case cancelled(take: Int)
    /// The released take was pasted, copied or rejected.
    case finished(take: Int, TakeEnd)
}

/// How a released take ended, in the overlay's words.
public enum TakeEnd: Equatable, Sendable {
    case pasted
    /// Left in the clipboard: no text field, or focus moved while transcribing.
    case copied
    /// The same short text the menu bar shows ("Too short", "Not recognized", …).
    case failed(String)
}

/// What the overlay shows after a take.
public struct OverlayResult: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case pasted, copied, error }

    public let kind: Kind
    public let text: String

    public init(_ end: TakeEnd) {
        switch end {
        case .pasted: (kind, text) = (.pasted, "Pasted")
        case .copied: (kind, text) = (.copied, "Copied")
        case .failed(let message): (kind, text) = (.error, message)
        }
    }

    /// The SF Symbol shown before the text.
    public var symbol: String {
        switch kind {
        case .pasted: "checkmark"
        case .copied: "doc.on.clipboard"
        case .error: "xmark"
        }
    }

    /// How long the result stays before the overlay fades out. Errors stay
    /// longer: they are the ones worth reading.
    public var duration: TimeInterval {
        kind == .error ? OverlayMachine.errorDuration : OverlayMachine.resultDuration
    }
}

/// What the overlay is showing.
public enum OverlayPhase: Equatable, Sendable {
    case hidden
    /// `since`: when the take started, on the machine's clock.
    case recording(since: TimeInterval)
    /// Released; waiting for the result. `elapsed`: how long the take recorded.
    case finishing(elapsed: TimeInterval)
    case result(OverlayResult)

    public var isVisible: Bool { self != .hidden }
}

/// Maps the coordinator's take events to what the overlay shows. Pure: the
/// caller passes the time and calls `tick` once `hideAt` has passed.
///
/// Only the newest take is followed. A new take replaces whatever is on
/// screen (also a result still showing); events of other takes are ignored.
public struct OverlayMachine: Equatable, Sendable {
    /// How long "Pasted" / "Copied" stay.
    public static let resultDuration: TimeInterval = 0.8
    /// How long an error stays.
    public static let errorDuration: TimeInterval = 1.5
    /// The fade-out once hidden.
    public static let fadeDuration: TimeInterval = 0.2

    public let style: OverlayStyle
    public private(set) var phase: OverlayPhase = .hidden
    /// When the result on screen should go; nil unless a result is showing.
    public private(set) var hideAt: TimeInterval?
    private var take: Int?

    public init(style: OverlayStyle) { self.style = style }

    public mutating func handle(_ event: TakeEvent, at now: TimeInterval) {
        guard style != .off else { return }
        switch event {
        case .started(let id):
            take = id
            set(.recording(since: now))
        case .released(let id):
            guard id == take, case .recording(let since) = phase else { return }
            set(.finishing(elapsed: now - since))
        case .cancelled(let id):
            guard id == take else { return }
            take = nil
            set(.hidden)
        case .finished(let id, let end):
            guard id == take, case .finishing = phase else { return }
            let result = OverlayResult(end)
            set(.result(result))
            hideAt = now + result.duration
        }
    }

    /// Hides a result whose time is up.
    public mutating func tick(at now: TimeInterval) {
        guard let hideAt, now >= hideAt else { return }
        take = nil
        set(.hidden)
    }

    private mutating func set(_ next: OverlayPhase) {
        phase = next
        hideAt = nil
    }

    /// Elapsed recording time as `m:ss`; negative or non-finite reads as 0:00.
    public static func elapsed(_ seconds: TimeInterval) -> String {
        let whole = seconds.isFinite ? max(0, Int(seconds.rounded(.down))) : 0
        let tail = whole % 60
        return "\(whole / 60):\(tail < 10 ? "0" : "")\(tail)"
    }
}
