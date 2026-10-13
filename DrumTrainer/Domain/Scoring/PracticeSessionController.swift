import Foundation

/// Owns session evidence and invalidates work across instrument boundaries.
/// AppState continues to coordinate audio scheduling through the existing transport.
@MainActor
final class PracticeSessionController {
    private(set) var instrument: InstrumentKind = .drums
    private(set) var generation: UInt64 = 0
    private(set) var minimumHostTime: UInt64 = 0
    var recording: PracticeSessionRecording?
    var sessionID: UUID?
    var pendingBounds: (startSessionTime: Int64, endSessionTime: Int64)?

    func activate(_ instrument: InstrumentKind, at hostTime: UInt64) {
        generation &+= 1
        self.instrument = instrument
        minimumHostTime = hostTime
        recording = nil
        sessionID = nil
        pendingBounds = nil
    }

    func accepts(_ event: PerformanceEvent) -> Bool {
        instrument == .drums && event.hostTime >= minimumHostTime
    }

    func record(_ event: PerformanceEvent) {
        guard accepts(event) else { return }
        recording?.record(event)
    }
}
