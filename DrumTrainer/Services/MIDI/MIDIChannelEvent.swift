import Foundation

enum MIDIChannelPayload: Codable, Equatable, Sendable {
    case noteOn(note: UInt8, velocity: UInt8)
    case noteOff(note: UInt8, velocity: UInt8)
    case controlChange(controller: UInt8, value: UInt8)
    case pitchBend(value: UInt16)
}

struct MIDIChannelEvent: Codable, Equatable, Sendable {
    let channel: UInt8 // Canonical public convention: 1–16.
    let group: UInt8
    let hostTime: UInt64
    let payload: MIDIChannelPayload
    let rawWord: UInt32
}

struct MIDIMessageBatch: Sendable {
    let events: [MIDIChannelEvent]
    let endpointID: Int32
    let endpointName: String
    let connectionGeneration: UInt64
    let droppedCount: Int
    let receivedHostTime: UInt64

    init(events: [MIDIChannelEvent], endpointID: Int32, endpointName: String,
         connectionGeneration: UInt64, droppedCount: Int, receivedHostTime: UInt64 = 0) {
        self.events = events
        self.endpointID = endpointID
        self.endpointName = endpointName
        self.connectionGeneration = connectionGeneration
        self.droppedCount = droppedCount
        self.receivedHostTime = receivedHostTime
    }
}

extension MIDI1UMPParser {
    static func channelEvent(from word: UInt32, hostTime: UInt64) -> MIDIChannelEvent? {
        guard word >> 28 == 2, word & 0x0000_8080 == 0 else { return nil }
        let status = UInt8((word >> 16) & 0xFF)
        let first = UInt8((word >> 8) & 0x7F)
        let second = UInt8(word & 0x7F)
        let payload: MIDIChannelPayload
        switch status & 0xF0 {
        case 0x90 where second > 0: payload = .noteOn(note: first, velocity: second)
        case 0x80, 0x90: payload = .noteOff(note: first, velocity: second)
        case 0xB0: payload = .controlChange(controller: first, value: second)
        case 0xE0: payload = .pitchBend(value: UInt16(first) | UInt16(second) << 7)
        default: return nil
        }
        return MIDIChannelEvent(channel: (status & 0x0F) + 1,
                                group: UInt8((word >> 24) & 0x0F),
                                hostTime: hostTime, payload: payload, rawWord: word)
    }

    /// Walk complete UMPs, not individual payload words. Lengths follow CoreMIDI's
    /// MIDIMessages.h; reserved/partial types stop parsing rather than invent notes.
    static func channelEvents(words: [UInt32], hostTime: UInt64) -> (events: [MIDIChannelEvent], dropped: Int) {
        var events: [MIDIChannelEvent] = []
        var index = 0
        var dropped = 0
        while index < words.count {
            let type = words[index] >> 28
            let length: Int
            switch type {
            case 0, 1, 2: length = 1
            case 3, 4: length = 2
            case 5, 0xD, 0xF: length = 4
            default: return (events, dropped + 1)
            }
            guard index + length <= words.count else { return (events, dropped + 1) }
            if let event = channelEvent(from: words[index], hostTime: hostTime) {
                events.append(event)
            } else if type == 4 || (type == 2 && words[index] & 0x0000_8080 != 0) {
                dropped += 1
            }
            index += length
        }
        return (events, dropped)
    }
}
