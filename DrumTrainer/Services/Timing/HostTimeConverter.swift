import AudioToolbox
import Foundation

protocol HostTimeConverting: Sendable {
    func nanoseconds(forHostTimeDuration hostTime: UInt64) -> UInt64
    func hostTime(forNanosecondDuration nanoseconds: UInt64) -> UInt64
}

struct CoreAudioHostTimeConverter: HostTimeConverting {
    func nanoseconds(forHostTimeDuration hostTime: UInt64) -> UInt64 {
        AudioConvertHostTimeToNanos(hostTime)
    }

    func hostTime(forNanosecondDuration nanoseconds: UInt64) -> UInt64 {
        AudioConvertNanosToHostTime(nanoseconds)
    }
}

struct LinearHostTimeConverter: HostTimeConverting {
    let nanosecondsPerTick: UInt64

    init(nanosecondsPerTick: UInt64 = 1) {
        precondition(nanosecondsPerTick > 0)
        self.nanosecondsPerTick = nanosecondsPerTick
    }

    func nanoseconds(forHostTimeDuration hostTime: UInt64) -> UInt64 {
        hostTime.multipliedReportingOverflow(by: nanosecondsPerTick).partialValue
    }

    func hostTime(forNanosecondDuration nanoseconds: UInt64) -> UInt64 {
        nanoseconds / nanosecondsPerTick
    }
}
