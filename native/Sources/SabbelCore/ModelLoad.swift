import Foundation

/// One progress report of the model load, independent of the engine.
public enum ModelLoadEvent: Equatable, Sendable {
    /// Listing the remote files before a download.
    case listing
    /// Downloading: `fraction` of this download in 0...1. `totalFiles` 0 is
    /// the cached path, where nothing is downloaded.
    case downloading(fraction: Double, totalFiles: Int)
    /// Compiling or loading a model.
    case loading
}

/// Turns load reports into the model state the menu shows: "Downloading
/// model… N%" only while something downloads, "Loading model..." while the
/// models compile and load (which can take a minute or two on first launch,
/// and must not look like a download stuck at its last percentage).
///
/// The engine loads several models, each with its own report that starts
/// over at 0, so the percentage belongs to the current download: it never
/// goes backwards within one, and starts over after a load phase.
public struct ModelLoadProgress: Sendable {
    /// The highest fraction of the current download, nil when none is running.
    private var download: Double?

    public init() {}

    public mutating func state(after event: ModelLoadEvent) -> ModelState {
        switch event {
        case .listing:
            break
        case .downloading(let fraction, let totalFiles) where totalFiles > 0:
            let clamped = min(1, max(0, fraction))
            download = max(download ?? 0, clamped)
        case .downloading, .loading:
            download = nil
        }
        return .loading(progress: download)
    }
}
