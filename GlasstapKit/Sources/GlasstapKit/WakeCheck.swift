import Foundation

/// An iPhone with its display off sends no frames. Once WDA runs and no frame has come within 4 s,
/// the check presses Home if SpringBoard is in front. In an app, Home would leave the app, so the
/// user gets a hint instead, until a frame comes.
public enum WakeCheck {
    public static let delay: Duration = .seconds(4)
    /// How often the check looks for a frame while the hint shows.
    public static let frameInterval: Duration = .seconds(1)

    /// Runs until a frame has come, the hint has gone again, or the task is cancelled.
    public static func run(statuses: AsyncStream<WDAStatus>,
                           hasFrame: @Sendable () -> Bool,
                           pressHomeIfSpringBoard: @Sendable () async -> Bool,
                           clock: any WDAClock,
                           showHint: @Sendable (Bool) async -> Void) async {
        // Without WDA, nothing can press Home, so the 4 s count from the moment that WDA runs.
        var wdaRuns = false
        for await status in statuses where status.state == .running {
            wdaRuns = true
            break
        }
        guard wdaRuns else { return }
        do { try await clock.sleep(for: delay) } catch { return }
        guard !hasFrame() else { return }
        let pressedHome = await pressHomeIfSpringBoard()
        guard !Task.isCancelled, !pressedHome, !hasFrame() else { return }
        await showHint(true)
        while !hasFrame() {
            do { try await clock.sleep(for: frameInterval) } catch { return }
        }
        await showHint(false)
    }
}
