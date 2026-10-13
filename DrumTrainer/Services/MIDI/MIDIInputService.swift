import CoreMIDI
import AudioToolbox
import Foundation

struct MIDIInputDevice: Identifiable, Hashable, Sendable {
    let id: MIDIUniqueID
    let endpoint: MIDIEndpointRef
    let name: String
}

struct MIDINoteOn: Equatable, Sendable {
    let channel: UInt8
    let note: UInt8
    let velocity: UInt8
    let hostTime: UInt64
}

enum MIDIInputStatus: Equatable, Sendable {
    case stopped
    case ready
    case noDevices
    case connected(String)
    case disconnected(String)
    case error(String)

    var message: String {
        switch self {
        case .stopped: "MIDI monitoring is stopped"
        case .ready: "Choose a MIDI input"
        case .noDevices: "No MIDI inputs found. Reconnect the module, then rescan."
        case let .connected(name): "Connected to \(name)"
        case let .disconnected(name): "\(name) disconnected; reconnect it or choose another input"
        case let .error(message): message
        }
    }
}

enum MIDI1UMPParser {
    static func noteOn(from word: UInt32, hostTime: UInt64) -> MIDINoteOn? {
        let messageType = UInt8((word >> 28) & 0x0F)
        guard messageType == 0x2 else { return nil }

        let statusByte = UInt8((word >> 16) & 0xFF)
        guard statusByte & 0xF0 == 0x90 else { return nil }

        let velocity = UInt8(word & 0x7F)
        guard velocity > 0 else { return nil }

        return MIDINoteOn(
            channel: (statusByte & 0x0F) + 1,
            note: UInt8((word >> 8) & 0x7F),
            velocity: velocity,
            hostTime: hostTime
        )
    }
}

final class MIDIInputService: @unchecked Sendable {
    typealias DevicesHandler = @Sendable ([MIDIInputDevice]) -> Void
    typealias NoteHandler = @Sendable (MIDINoteOn, String) -> Void
    typealias StatusHandler = @Sendable (MIDIInputStatus) -> Void
    typealias MessagesHandler = @Sendable (MIDIMessageBatch) -> Void

    private let onDevicesChanged: DevicesHandler
    private let onNoteOn: NoteHandler
    private let onStatusChanged: StatusHandler
    private let onMessages: MessagesHandler
    private var inputGeneration: UInt64 = 0

    var connectionGeneration: UInt64 { stateLock.withLock { inputGeneration } }
    private let stateLock = NSLock()

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var selectedEndpoint = MIDIEndpointRef()
    private var selectedID: MIDIUniqueID?
    private var selectedName: String?
    private var isStarted = false

    init(
        onDevicesChanged: @escaping DevicesHandler,
        onNoteOn: @escaping NoteHandler,
        onStatusChanged: @escaping StatusHandler,
        onMessages: @escaping MessagesHandler = { _ in }
    ) {
        self.onDevicesChanged = onDevicesChanged
        self.onNoteOn = onNoteOn
        self.onStatusChanged = onStatusChanged
        self.onMessages = onMessages
    }

    deinit {
        if selectedEndpoint != 0, inputPort != 0 {
            MIDIPortDisconnectSource(inputPort, selectedEndpoint)
        }
        if inputPort != 0 { MIDIPortDispose(inputPort) }
        if client != 0 { MIDIClientDispose(client) }
    }

    func start() {
        stateLock.lock()
        guard !isStarted else {
            stateLock.unlock()
            refreshDevices()
            return
        }
        stateLock.unlock()

        var newClient = MIDIClientRef()
        let clientStatus = MIDIClientCreateWithBlock("DrumTrainer MIDI" as CFString, &newClient) { [weak self] _ in
            self?.refreshDevices()
        }
        guard clientStatus == noErr else {
            onStatusChanged(.error("CoreMIDI could not start (error \(clientStatus))."))
            return
        }

        var newPort = MIDIPortRef()
        let portStatus = MIDIInputPortCreateWithProtocol(
            newClient,
            "DrumTrainer Input" as CFString,
            ._1_0,
            &newPort
        ) { [weak self] eventList, context in
            self?.receive(eventList, generation: UInt64(UInt(bitPattern: context)))
        }

        guard portStatus == noErr else {
            MIDIClientDispose(newClient)
            onStatusChanged(.error("CoreMIDI could not create an input port (error \(portStatus))."))
            return
        }

        stateLock.lock()
        client = newClient
        inputPort = newPort
        isStarted = true
        stateLock.unlock()

        onStatusChanged(.ready)
        refreshDevices()
    }

    func select(deviceID: MIDIUniqueID?) {
        stateLock.lock()
        inputGeneration &+= 1
        let generation = inputGeneration
        let port = inputPort
        let previousEndpoint = selectedEndpoint
        stateLock.unlock()

        guard port != 0 else {
            onStatusChanged(.error("MIDI is not ready yet."))
            return
        }

        if previousEndpoint != 0 {
            MIDIPortDisconnectSource(port, previousEndpoint)
        }

        guard let deviceID else {
            stateLock.lock()
            selectedEndpoint = 0
            selectedID = nil
            selectedName = nil
            stateLock.unlock()
            onStatusChanged(.ready)
            return
        }

        guard let device = Self.availableDevices().first(where: { $0.id == deviceID }) else {
            onStatusChanged(.disconnected("Selected MIDI input"))
            return
        }

        let status = MIDIPortConnectSource(port, device.endpoint, UnsafeMutableRawPointer(bitPattern: UInt(generation)))
        guard status == noErr else {
            onStatusChanged(.error("Could not connect to \(device.name) (error \(status))."))
            return
        }

        stateLock.lock()
        selectedEndpoint = device.endpoint
        selectedID = device.id
        selectedName = device.name
        stateLock.unlock()
        onStatusChanged(.connected(device.name))
    }

    private func refreshDevices() {
        let devices = Self.availableDevices()
        onDevicesChanged(devices)

        stateLock.lock()
        let activeID = selectedID
        let activeName = selectedName
        let port = inputPort
        let oldEndpoint = selectedEndpoint
        stateLock.unlock()

        guard let activeID else {
            onStatusChanged(devices.isEmpty ? .noDevices : .ready)
            return
        }
        guard let replacement = devices.first(where: { $0.id == activeID }) else {
            if oldEndpoint != 0, port != 0 { MIDIPortDisconnectSource(port, oldEndpoint) }
            stateLock.lock()
            selectedEndpoint = 0
            inputGeneration &+= 1
            stateLock.unlock()
            onStatusChanged(.disconnected(activeName ?? "Selected MIDI input"))
            return
        }

        if replacement.endpoint != oldEndpoint, port != 0 {
            if oldEndpoint != 0 { MIDIPortDisconnectSource(port, oldEndpoint) }
            let generation = stateLock.withLock { inputGeneration &+= 1; return inputGeneration }
            if MIDIPortConnectSource(port, replacement.endpoint, UnsafeMutableRawPointer(bitPattern: UInt(generation))) == noErr {
                stateLock.lock()
                selectedEndpoint = replacement.endpoint
                selectedName = replacement.name
                stateLock.unlock()
                onStatusChanged(.connected(replacement.name))
            }
        }
    }

    private func receive(_ eventList: UnsafePointer<MIDIEventList>, generation: UInt64) {
        let receivedHostTime = AudioGetCurrentHostTime()
        let context = stateLock.withLock { (selectedID, selectedName ?? "MIDI input", inputGeneration) }
        guard let endpointID = context.0, generation == context.2 else { return }
        var events: [MIDIChannelEvent] = []
        var dropped = 0
        // CoreMIDI packets and lists are variable-length. Taking a Swift value
        // copy of .packet truncates it to the 64-word declaration and breaks Next.
        let packetOffset = MemoryLayout<MIDIEventList>.offset(of: \.packet)!
        var packetPointer = UnsafeRawPointer(eventList).advanced(by: packetOffset).assumingMemoryBound(to: MIDIEventPacket.self)
        for _ in 0..<eventList.pointee.numPackets {
            let wordCount = Int(packetPointer.pointee.wordCount)
            let count = min(wordCount, 4_096)
            let wordOffset = MemoryLayout<MIDIEventPacket>.offset(of: \.words)!
            let base = UnsafeRawPointer(packetPointer).advanced(by: wordOffset).assumingMemoryBound(to: UInt32.self)
            let parsed = MIDI1UMPParser.channelEvents(words: Array(UnsafeBufferPointer(start: base, count: count)),
                                                     hostTime: packetPointer.pointee.timeStamp)
            dropped += parsed.dropped + max(wordCount - count, 0)
            for event in parsed.events {
                if events.count < 4_096 { events.append(event) }
                else { dropped += 1 }
            }
            packetPointer = UnsafePointer(MIDIEventPacketNext(packetPointer))
        }
        guard connectionGeneration == generation else { return }
        onMessages(MIDIMessageBatch(events: events, endpointID: endpointID, endpointName: context.1,
                                   connectionGeneration: generation, droppedCount: dropped, receivedHostTime: receivedHostTime))
        for event in events {
            if case let .noteOn(note, velocity) = event.payload {
                onNoteOn(MIDINoteOn(channel: event.channel, note: note, velocity: velocity, hostTime: event.hostTime), context.1)
            }
        }
    }

    private static func availableDevices() -> [MIDIInputDevice] {
        (0..<MIDIGetNumberOfSources()).compactMap { index in
            let endpoint = MIDIGetSource(index)
            guard endpoint != 0 else { return nil }

            var uniqueID = MIDIUniqueID()
            if MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uniqueID) != noErr {
                // Some class-compliant and virtual endpoints omit a unique-ID property.
                // Keep them selectable for this CoreMIDI session using the endpoint ref.
                uniqueID = MIDIUniqueID(bitPattern: endpoint)
            }

            var displayName: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &displayName)
            let name = displayName?.takeRetainedValue() as String? ?? "MIDI Input \(index + 1)"
            return MIDIInputDevice(id: uniqueID, endpoint: endpoint, name: name)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
