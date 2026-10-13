import Foundation

struct PianoNoteTracker: Sendable {
    private(set) var notes: [UUID: PianoPlayedNote] = [:]
    private var order: [UUID] = []
    private var heldKeys: [PianoKeyIdentity: UUID] = [:]
    private(set) var sustainChannels: Set<PianoChannelIdentity> = []
    private var bentChannels: Set<PianoChannelIdentity> = []
    private(set) var droppedCount = 0
    private(set) var issueCount = 0
    private var lastTime: Int64 = .min
    let capacity: Int
    let retainsSessionEvidence: Bool

    init(capacity: Int = 512, retainsSessionEvidence: Bool = false) {
        self.capacity = max(capacity, 1)
        self.retainsSessionEvidence = retainsSessionEvidence
    }

    var orderedNotes: [PianoPlayedNote] { order.compactMap { notes[$0] } }
    var heldPitches: Set<MIDIPitch> { Set(notes.values.filter(\.isKeyDown).map(\.pitch)) }
    var soundingPitches: Set<MIDIPitch> { Set(notes.values.filter(\.isSounding).map(\.pitch)) }
    var hasActiveNotes: Bool { notes.values.contains { $0.isKeyDown || $0.isSounding } }

    mutating func process(_ event: PianoInputEvent) {
        guard (1...16).contains(event.message.channel), event.message.group < 16,
              event.sessionTimeNanoseconds >= lastTime else { issueCount += 1; return }
        lastTime = event.sessionTimeNanoseconds
        let input = PianoChannelIdentity(endpointID: event.endpointID, group: event.message.group, channel: event.message.channel)
        let time = event.sessionTimeNanoseconds
        switch event.message.payload {
        case let .noteOn(number, velocity):
            guard let pitch = MIDIPitch(Int(number)), velocity > 0, velocity <= 127 else { issueCount += 1; return }
            let key = PianoKeyIdentity(input: input, pitch: pitch)
            let overlaps = heldKeys[key] != nil
            if let old = heldKeys.removeValue(forKey: key) {
                notes[old]?.isUncertain = true
                notes[old]?.isInterrupted = true
                issueCount += 1
            }
            if notes.count >= capacity {
                if !retainsSessionEvidence,
                   let old = order.first(where: { notes[$0]?.isSounding == false }) {
                    notes.removeValue(forKey: old)
                    order.removeAll { $0 == old }
                } else { droppedCount += 1; return }
            }
            let note = PianoPlayedNote(id: UUID(), input: input, pitch: pitch, velocity: velocity,
                                      onsetHostTime: event.effectiveHostTime, onsetNanoseconds: time,
                                      isUncertain: overlaps || bentChannels.contains(input))
            notes[note.id] = note
            order.append(note.id)
            heldKeys[key] = note.id
        case let .noteOff(number, _):
            guard let pitch = MIDIPitch(Int(number)) else { issueCount += 1; return }
            let key = PianoKeyIdentity(input: input, pitch: pitch)
            guard let id = heldKeys.removeValue(forKey: key) else { return }
            notes[id]?.keyReleaseNanoseconds = time
            if !sustainChannels.contains(input) { notes[id]?.soundingEndNanoseconds = time }
        case let .controlChange(controller, value):
            switch controller {
            case 64:
                if value >= 64 { sustainChannels.insert(input) }
                else { releaseSustain(input, at: time) }
            case 121:
                releaseSustain(input, at: time)
                bentChannels.remove(input)
            case 120, 123:
                // All Notes Off affects held keys; already-released pedal tones
                // continue until pedal-up. All Sound Off also ends those tones.
                let affected = order.filter { id in
                    guard let note = notes[id], note.input == input else { return false }
                    return controller == 120 ? note.isSounding : note.isKeyDown
                }
                for id in affected {
                    notes[id]?.isInterrupted = true
                    if controller == 120 || !sustainChannels.contains(input) { notes[id]?.soundingEndNanoseconds = time }
                }
                heldKeys = heldKeys.filter { $0.key.input != input }
                if !affected.isEmpty { issueCount += 1 }
            default: break
            }
        case let .pitchBend(value):
            if value == 8192 { bentChannels.remove(input) }
            else {
                bentChannels.insert(input)
                for id in order where notes[id]?.input == input && notes[id]?.isSounding == true {
                    notes[id]?.isUncertain = true
                }
            }
        }
    }

    mutating func markDropped(_ count: Int) { droppedCount += max(count, 0) }

    private mutating func releaseSustain(_ input: PianoChannelIdentity, at time: Int64) {
        sustainChannels.remove(input)
        for id in order where notes[id]?.input == input && notes[id]?.keyReleaseNanoseconds != nil && notes[id]?.soundingEndNanoseconds == nil {
            notes[id]?.soundingEndNanoseconds = time
        }
    }
}
