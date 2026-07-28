import XCTest
@testable import Relay

final class LogTests: XCTestCase {
    /// Regression: `Log` used to write into `~/.claude/relay/relay.log` unconditionally, so
    /// every test run interleaved fake entries with the running daemon's. That file is a
    /// primary diagnostic surface — polluting it turns a real investigation into a hunt for
    /// which lines are genuine.
    func testTestRunsDoNotWriteIntoTheUserLog() {
        XCTAssertTrue(Log.isRunningTests, "this suite is, by definition, a test run")
        XCTAssertNotEqual(Log.fileURL.standardizedFileURL,
                          ConfigStore.directory.appendingPathComponent("relay.log").standardizedFileURL,
                          "the test process must not log into the user's relay.log")
        XCTAssertFalse(Log.fileURL.path.hasPrefix(ConfigStore.directory.path),
                       "the test log must live outside the real config directory entirely")
    }

    /// The redirect has to actually carry the writes, not just the path: a log line emitted
    /// under test must land in the throwaway file.
    func testLogLinesLandInTheRedirectedFile() throws {
        let marker = "log-redirect-probe-\(UUID().uuidString)"
        Log.info(marker)

        // Writes are queued off the caller's thread; give the queue a moment to drain.
        let deadline = Date().addingTimeInterval(2)
        var contents = ""
        while Date() < deadline {
            contents = (try? String(contentsOf: Log.fileURL, encoding: .utf8)) ?? ""
            if contents.contains(marker) { break }
            usleep(50_000)
        }
        XCTAssertTrue(contents.contains(marker), "the line never reached \(Log.fileURL.path)")
    }
}
