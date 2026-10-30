import AVFoundation
import Testing
@testable import TranslationWorkbench

// These tests exercise playback using generated silence, never microphone
// permission or capture. Passing them is not evidence of real recording.
@Suite(.serialized)
@MainActor
struct PlaybackTests {
    @Test func paragraphPlaybackStartsAtTheRequestedPointAndRejectsStaleTimes() async throws {
        let fixture = try SilentAudioFixture(seconds: 1)
        defer { fixture.remove() }
        let playback = PlaybackController()
        defer { playback.stop() }
        try playback.play(at: 0.4, from: fixture.url)
        #expect(playback.isPlaying)
        #expect(playback.currentTime == 0.4)
        try playback.play(at: 0.2, from: fixture.url)
        #expect(playback.isPlaying)
        #expect(playback.currentTime == 0.2)
        #expect(throws: (any Error).self) { try playback.play(at: 2, from: fixture.url) }
        #expect(!playback.isPlaying)
        #expect(playback.lastError != nil)
        #expect(playback.currentTime != 0)
    }

    @Test
    func testPreparedAudioDurationAndSeekingAreBounded() async throws {
        let fixture = try SilentAudioFixture(seconds: 1)
        defer { fixture.remove() }
        let playback = PlaybackController()

        try playback.load(fixture.url)

        #expect(playback.loadedURL == fixture.url)
        #expect(abs(playback.duration - 1) <= 1.0 / 48_000)
        #expect(playback.currentTime == 0)
        #expect(!playback.isPlaying)
        #expect(playback.lastError == nil)

        playback.seek(to: 0.4)
        #expect(abs(playback.currentTime - 0.4) <= 0.001)
        playback.seek(to: -.infinity)
        #expect(abs(playback.currentTime - 0.4) <= 0.001)
        playback.seek(to: .nan)
        #expect(abs(playback.currentTime - 0.4) <= 0.001)
        playback.seek(to: -10)
        #expect(playback.currentTime == 0)
        playback.seek(to: 10)
        #expect(playback.currentTime == playback.duration)
        #expect(!playback.isPlaying)
    }

    @Test
    func testLoadingMissingAudioClearsOldStateAndAllowsRecovery() async throws {
        let fixture = try SilentAudioFixture(seconds: 1)
        defer { fixture.remove() }
        let playback = PlaybackController()
        try playback.load(fixture.url)
        playback.seek(to: 0.5)

        let missing = fixture.directory.appendingPathComponent("missing.caf")
        #expect(throws: (any Error).self) { try playback.load(missing) }
        #expect(playback.loadedURL == nil)
        #expect(playback.duration == 0)
        #expect(playback.currentTime == 0)
        #expect(!playback.isPlaying)
        #expect(playback.lastError != nil)
        #expect(throws: (any Error).self) { try playback.toggle() }

        playback.dismissError()
        #expect(playback.lastError == nil)
        try playback.load(fixture.url)
        #expect(playback.lastError == nil)
        #expect(abs(playback.duration - 1) <= 1.0 / 48_000)
        #expect(playback.loadedURL == fixture.url)
    }

    @Test
    func testSilentPlaybackCanPauseSeekStopAndReplay() async throws {
        let fixture = try SilentAudioFixture(seconds: 1)
        defer { fixture.remove() }
        let playback = PlaybackController()
        defer { playback.stop() }
        try playback.load(fixture.url)

        try playback.toggle()
        #expect(playback.isPlaying)
        try await Task.sleep(nanoseconds: 80_000_000)
        try playback.toggle()
        #expect(!playback.isPlaying)
        #expect(playback.currentTime > 0)
        let pausedAt = playback.currentTime
        try await Task.sleep(nanoseconds: 80_000_000)
        #expect(abs(playback.currentTime - pausedAt) <= 0.001)

        playback.seek(to: playback.duration)
        #expect(playback.currentTime == playback.duration)
        try playback.toggle()
        #expect(playback.isPlaying)
        #expect(abs(playback.currentTime) <= 0.001)

        playback.stop()
        #expect(!playback.isPlaying)
        #expect(playback.currentTime == 0)
        #expect(playback.loadedURL == fixture.url)
        try playback.toggle()
        #expect(playback.isPlaying)
        playback.stop()
    }

    @Test
    func testNaturalCompletionAllowsReplayAndStopStaysStopped() async throws {
        let fixture = try SilentAudioFixture(seconds: 0.15)
        defer { fixture.remove() }
        let playback = PlaybackController()
        defer { playback.stop() }
        try playback.load(fixture.url)
        try playback.toggle()

        // Bounded wait for the real AVAudioPlayer delegate, not simulated time.
        for _ in 0..<80 {
            if !playback.isPlaying { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(!playback.isPlaying, "Silent playback did not complete within two seconds.")
        #expect(abs(playback.currentTime - playback.duration) <= 0.001)
        #expect(playback.lastError == nil)

        try playback.toggle()
        #expect(playback.isPlaying)
        #expect(abs(playback.currentTime) <= 0.001)
        playback.stop()
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(!playback.isPlaying)
        #expect(playback.currentTime == 0)
        #expect(playback.lastError == nil)
    }
}

private struct SilentAudioFixture {
    let directory: URL
    let url: URL

    init(seconds: TimeInterval) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-audio-test-\(UUID().uuidString)", isDirectory: true)
        url = directory.appendingPathComponent("generated-silence.caf")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let frames = AVAudioFrameCount(seconds * 48_000)
            let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: true))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            buffer.frameLength = frames
            let samples = try #require(buffer.int16ChannelData?[0])
            samples.initialize(repeating: 0, count: Int(frames))
            let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
            try file.write(from: buffer)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
