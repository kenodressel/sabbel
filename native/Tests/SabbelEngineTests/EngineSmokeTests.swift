import FluidAudio
import SabbelCore
import Testing
@testable import SabbelEngine

@Test func engineLinks() { #expect(SabbelEngine.name == "SabbelEngine") }

/// FluidAudio's repo loads report one fraction for download (the first half)
/// and compile (the second half); the app needs the phase and the download's own fraction.
@Suite struct LoadEventMappingTests {
    @Test func listing() {
        #expect(ParakeetRecognizer.event(DownloadProgress(fractionCompleted: 0, phase: .listing)) == .listing)
    }

    @Test func downloadingIsScaledToTheDownloadPhase() {
        let event = ParakeetRecognizer.event(
            DownloadProgress(fractionCompleted: 0.25, phase: .downloading(completedFiles: 1, totalFiles: 4)))
        #expect(event == .downloading(fraction: 0.5, totalFiles: 4))
    }

    @Test func compilingIsLoading() {
        #expect(ParakeetRecognizer.event(DownloadProgress(fractionCompleted: 0.75, phase: .compiling(modelName: "x"))) == .loading)
    }

    @Test func cachedPathKeepsZeroFiles() {
        let event = ParakeetRecognizer.event(
            DownloadProgress(fractionCompleted: 0.5, phase: .downloading(completedFiles: 0, totalFiles: 0)))
        #expect(event == .downloading(fraction: 1, totalFiles: 0))
    }
}
