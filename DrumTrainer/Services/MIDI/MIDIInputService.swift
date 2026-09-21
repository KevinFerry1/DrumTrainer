import CoreMIDI
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

    private let onDevicesChanged: DevicesHandler
    private let onNoteOn: NoteHandler
    private let onStatusChanged: StatusHandler
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
        onStatusChanged: @escaping StatusHandler
    ) {
        self.onDevicesChanged = onDevicesChanged
        self.onNoteOn = onNoteOn
        self.onStatusChanged = onStatusChanged
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
        ) { [weak self] eventList, _ in
            self?.receive(eventList)
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

        let status = MIDIPortConnectSource(port, device.endpoint, nil)
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
            stateLock.unlock()
            onStatusChanged(.disconnected(activeName ?? "Selected MIDI input"))
            return
        }

        if replacement.endpoint != oldEndpoint, port != 0 {
            if oldEndpoint != 0 { MIDIPortDisconnectSource(port, oldEndpoint) }
            if MIDIPortConnectSource(port, replacement.endpoint, nil) == noErr {
                stateLock.lock()
                selectedEndpoint = replacement.endpoint
                selectedName = replacement.name
                stateLock.unlock()
                onStatusChanged(.connected(replacement.name))
            }
        }
    }

    private func receive(_ eventList: UnsafePointer<MIDIEventList>) {
        stateLock.lock()
        let endpointName = selectedName ?? "MIDI input"
        stateLock.unlock()

        withUnsafePointer(to: eventList.pointee.packet) { firstPacket in
            var packetPointer = firstPacket
            for _ in 0..<eventList.pointee.numPackets {
                let packet = packetPointer.pointee
                withUnsafeBytes(of: packet.words) { rawWords in
                    let words = rawWords.bindMemory(to: UInt32.self)
                    for index in 0..<Int(packet.wordCount) {
                        if let note = MIDI1UMPParser.noteOn(
                            from: words[index],
                            hostTime: packet.timeStamp
                        ) {
                            onNoteOn(note, endpointName)
                        }
                    }
                }
                packetPointer = UnsafePointer(MIDIEventPacketNext(packetPointer))
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
