import AudioToolbox
import Foundation

protocol ClockProviding: Sendable {
    func currentHostTime() -> UInt64
}

struct MachHostClock: ClockProviding {
    func currentHostTime() -> UInt64 {
        AudioGetCurrentHostTime()
    }
}

struct FixedHostClock: ClockProviding {
    let hostTime: UInt64

    func currentHostTime() -> UInt64 { hostTime }
}
