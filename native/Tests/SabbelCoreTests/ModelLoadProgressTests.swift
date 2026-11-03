import Testing
@testable import SabbelCore

@Suite struct ModelLoadProgressTests {
    private func states(_ events: [ModelLoadEvent]) -> [ModelState] {
        var progress = ModelLoadProgress()
        return events.map { progress.state(after: $0) }
    }

    @Test func downloadingShowsItsFraction() {
        #expect(states([.downloading(fraction: 0.25, totalFiles: 4)]) == [.loading(progress: 0.25)])
    }

    /// Compiling and loading are not downloading: "Loading model...", not a stuck percentage.
    @Test func compilingShowsLoading() {
        #expect(states([.downloading(fraction: 1, totalFiles: 4), .loading]) == [.loading(progress: 1), .loading(progress: nil)])
    }

    /// The cached path reports a download phase with no files: nothing is downloading.
    @Test func cachedModelsShowLoading() {
        #expect(states([.listing, .downloading(fraction: 1, totalFiles: 0), .loading])
                == [.loading(progress: nil), .loading(progress: nil), .loading(progress: nil)])
    }

    @Test func percentNeverGoesBackwardsWithinADownload() {
        #expect(states([.downloading(fraction: 0.6, totalFiles: 4), .downloading(fraction: 0.4, totalFiles: 4)])
                == [.loading(progress: 0.6), .loading(progress: 0.6)])
    }

    /// Listing between two reports of one download keeps the percentage on screen.
    @Test func listingKeepsTheCurrentDownload() {
        #expect(states([.downloading(fraction: 0.3, totalFiles: 4), .listing])
                == [.loading(progress: 0.3), .loading(progress: 0.3)])
    }

    /// The next model's download starts after a load phase, at its own fraction.
    @Test func aNewDownloadAfterLoadingStartsOver() {
        #expect(states([.downloading(fraction: 0.9, totalFiles: 4), .loading, .downloading(fraction: 0.1, totalFiles: 2)])
                == [.loading(progress: 0.9), .loading(progress: nil), .loading(progress: 0.1)])
    }

    @Test func fractionIsClamped() {
        #expect(states([.downloading(fraction: 1.7, totalFiles: 1)]) == [.loading(progress: 1)])
        #expect(states([.downloading(fraction: -0.2, totalFiles: 1)]) == [.loading(progress: 0)])
    }
}
