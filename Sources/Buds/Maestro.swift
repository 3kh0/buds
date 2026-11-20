import Foundation
import IOBluetooth

enum MaestroWire {
    static func hash(_ string: String) -> UInt32 {
        var result = UInt32(string.utf8.count)
        var coefficient: UInt32 = 65599
        for byte in string.utf8 {
            result = result &+ coefficient &* UInt32(byte)
            coefficient = coefficient &* 65599
        }
        return result
    }
    static func varint(_ input: UInt64) -> [UInt8] {
        var value = input
        var bytes: [UInt8] = []
        repeat {
            bytes.append(UInt8(value & 127) | (value > 127 ? 128 : 0))
            value >>= 7
        } while value > 0
        return bytes
    }
    static func crc(_ bytes: [UInt8]) -> UInt32 {
        var value: UInt32 = .max
        for byte in bytes {
            value ^= UInt32(byte)
            for _ in 0..<8 { value = value & 1 != 0 ? (value >> 1) ^ 0xedb88320 : value >> 1 }
        }
        return ~value
    }
    static func littleEndian(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }
    static func request(channel: UInt32, method: String, call: UInt32, payload: [UInt8] = [], type: UInt32 = 0, status: UInt32 = 0) -> [UInt8] {
        let peers: [UInt32: (UInt32, UInt32)] = [18: (10, 2), 19: (10, 3), 21: (10, 4), 23: (13, 2), 24: (13, 3), 26: (13, 4)]
        guard let (source, target) = peers[channel] else { return [] }
        var address = source << 6 | target << 10
        var frame: [UInt8] = []
        repeat {
            frame.append(UInt8((address & 127) << 1) | (address <= 127 ? 1 : 0))
            address >>= 7
        } while address > 0
        frame += [3]
        if type != 0 { frame += [0x08] + varint(UInt64(type)) }
        frame += [0x10] + varint(UInt64(channel))
        frame += [0x1d] + littleEndian(hash("maestro_pw.Maestro"))
        frame += [0x25] + littleEndian(hash(method))
        if !payload.isEmpty { frame += [0x2a] + varint(UInt64(payload.count)) + payload }
        if status != 0 { frame += [0x30] + varint(UInt64(status)) }
        frame += [0x38] + varint(UInt64(call))
        frame += littleEndian(crc(frame))
        return [0x7e] + frame.flatMap { $0 == 0x7e || $0 == 0x7d ? [0x7d, $0 ^ 0x20] : [$0] } + [0x7e]
    }

    static func placement(_ payload: [UInt8]) -> (leftInCase: Bool, rightInCase: Bool)? {
        guard let runtime = fields(payload), let bytes = runtime[7]?.bytes,
              let placement = fields(bytes) else { return nil }
        return ((placement[2]?.number ?? 0) != 0, (placement[1]?.number ?? 0) != 0)
    }

    static func settingValue(_ id: Int, value: Int) -> [UInt8] {
        let setting = varint(UInt64(id << 3)) + varint(UInt64(value))
        return [0x22] + varint(UInt64(setting.count)) + setting
    }

    static func settings(_ payload: [UInt8]) -> [Int: Int] {
        guard let wrapper = fields(payload), let bytes = wrapper[4]?.bytes,
              let values = fields(bytes) else { return [:] }
        return values.filter { [11, 13, 22].contains($0.key) }
            .reduce(into: [:]) { $0[$1.key] = Int($1.value.number) }
    }

    struct Field {
        var number: UInt64 = 0
        var bytes: [UInt8] = []
    }
    static func fields(_ bytes: [UInt8]) -> [Int: Field]? {
        var index = 0
        func readVarint() -> UInt64? {
            var result: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard index < bytes.count else { return nil }
                let byte = bytes[index]; index += 1
                if shift == 63 && byte > 1 { return nil }
                result |= UInt64(byte & 127) << shift
                if byte & 128 == 0 { return result }
            }
            return nil
        }
        var result: [Int: Field] = [:]
        while index < bytes.count {
            guard let tag = readVarint(), tag >> 3 > 0 else { return nil }
            let key = Int(tag >> 3)
            switch tag & 7 {
            case 0:
                guard let value = readVarint() else { return nil }
                result[key] = Field(number: value)
            case 1, 5:
                let size = tag & 7 == 1 ? 8 : 4
                guard index + size <= bytes.count else { return nil }
                var value: UInt64 = 0
                for offset in 0..<size { value |= UInt64(bytes[index + offset]) << (offset * 8) }
                result[key] = Field(number: value)
                index += size
            case 2:
                guard let length = readVarint(), length <= UInt64(bytes.count - index) else { return nil }
                result[key] = Field(bytes: Array(bytes[index..<(index + Int(length))]))
                index += Int(length)
            default: return nil
            }
        }
        return result
    }
}

func closeBluetoothChannel(_ channel: IOBluetoothRFCOMMChannel?, onHang: (() -> Void)?) {
    guard let channel else { return }
    let deadline = WriteDeadline()
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
        if deadline.isPending { onHang?() }
    }
    channel.setDelegate(nil)
    channel.close()
    deadline.finish()
}

private final class RFCOMMWriteBuffer {
    let pointer: UnsafeMutableRawPointer
    let count: Int
    let deadline = WriteDeadline()
    init(_ bytes: [UInt8]) {
        count = bytes.count
        pointer = .allocate(byteCount: bytes.count, alignment: 1)
        bytes.withUnsafeBytes { pointer.copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
    }
    deinit { pointer.deallocate() }
}

final class MaestroBattery: NSObject, IOBluetoothRFCOMMChannelDelegate {
    private var channel: IOBluetoothRFCOMMChannel?
    private var buffer: [UInt8] = []
    private var escaped = false
    private var resolved: UInt32?
    private var began = false
    private var openTimer: Timer?
    private var nextCall: UInt32 = 300
    private var writes: [UInt32: Int] = [:]
    private var runtimeCall: UInt32 = 2
    private var runtimeWatchdog = RuntimeWatchdog()
    private var healthTimer: Timer?
    private var openedAt = Date()
    private var nextWriteID: UInt = 0
    private var pendingWrites: [UInt: RFCOMMWriteBuffer] = [:]
    private var outbound: [UInt] = []
    private var inFlightWrite: UInt?
    private var session = UUID()
    var onSetting: ((Int, Int) -> Void)?
    var onWriteFailure: ((Int, String) -> Void)?
    var onFailure: (() -> Void)?
    var onTransportHang: (() -> Void)?
    var onOpen: (() -> Void)?
    var isActive: Bool { channel != nil }
    var isReady: Bool { channel?.isOpen() == true && resolved != nil }
    var onPlacement: ((Bool, Bool) -> Void)?
    var onBattery: ((BatteryReading, BatteryReading, BatteryReading) -> Void)?

    func connect(_ device: IOBluetoothDevice) -> Bool {
        guard channel == nil else { return true }
        let uuid = IOBluetoothSDPUUID(data: Data([0x25, 0xe9, 0x7f, 0xf7, 0x24, 0xce, 0x4c, 0x4c, 0x89, 0x51, 0xf7, 0x64, 0xa7, 0x08, 0xf7, 0xb5]))
        guard let service = device.getServiceRecord(for: uuid) else { trace("Maestro service unavailable"); return false }
        var channelID: BluetoothRFCOMMChannelID = 0
        guard service.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else { return false }
        let result = device.openRFCOMMChannelAsync(&channel, withChannelID: channelID, delegate: self)
        trace("Maestro open channel \(channelID): \(result)")
        if result != kIOReturnSuccess { channel = nil; return false }
        // IOBluetooth may return an existing channel. Explicitly register the
        // data listener again: an open cannot finish without a registered client.
        let registration = channel?.setDelegate(self) ?? kIOReturnNotOpen
        trace("Maestro listener registration: \(registration), open: \(channel?.isOpen() == true)")
        guard registration == kIOReturnSuccess else { disconnect(); return false }
        var attempts = 0
        openTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            attempts += 1
            if self.channel?.isOpen() == true {
                self.beginRequests()
                timer.invalidate()
            } else if attempts >= 40 {
                self.trace("Maestro channel did not open")
                self.disconnect()
                timer.invalidate()
                self.onFailure?()
            }
        }
        return true
    }
    func prepareForExit() {
        openTimer?.invalidate()
        healthTimer?.invalidate()
        onTransportHang = nil
        onFailure = nil
        for write in pendingWrites.values { write.deadline.finish() }
    }

    func disconnect() {
        session = UUID()
        let oldWrites = pendingWrites
        for write in oldWrites.values { write.deadline.finish() }
        pendingWrites = [:]
        outbound = []
        inFlightWrite = nil
        openTimer?.invalidate()
        openTimer = nil
        began = false
        healthTimer?.invalidate()
        healthTimer = nil
        let oldChannel = channel
        channel = nil
        closeBluetoothChannel(oldChannel, onHang: onTransportHang)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { withExtendedLifetime((oldChannel, oldWrites)) {} }
        buffer = []
        resolved = nil
        writes = [:]
        escaped = false
    }
    func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        guard channel == nil || rfcommChannel == channel else { return }
        channel = rfcommChannel
        trace("Maestro open complete: \(error)")
        guard error == kIOReturnSuccess else { disconnect(); onFailure?(); return }
        beginRequests()
        onOpen?()
    }
    private func beginRequests() {
        guard !began else { return }
        began = true
        openedAt = Date()
        healthTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.checkHealth() }
        RunLoop.main.add(healthTimer!, forMode: .common)
        for id: UInt32 in [18, 19, 21, 23, 24, 26] { send(id, "GetSoftwareInfo", call: 1) }
    }
    private func failConnection() {
        disconnect()
        onFailure?()
    }
    private func checkHealth() {
        pumpWrites()
        guard channel?.isOpen() == true else { failConnection(); return }
        guard resolved != nil else {
            if Date().timeIntervalSince(openedAt) >= 8 { failConnection() }
            return
        }
        switch runtimeWatchdog.action() {
        case .none: break
        case .renew: renewRuntime()
        case .reconnect:
            trace("Runtime snapshot timed out; reconnecting")
            failConnection()
        }
    }
    func refreshSnapshot() {
        guard isReady else { return }
        renewRuntime()
    }

    private func renewRuntime() {
        guard let resolved else { return }
        // Pigweed cancels a server stream with CLIENT_ERROR / CANCELLED.
        // Cancel before re-subscribing to avoid accumulating subscriptions.
        let oldCall = runtimeCall
        runtimeCall &+= 1
        runtimeWatchdog.requested()
        guard send(resolved, "SubscribeRuntimeInfo", call: oldCall, type: 4, status: 1) else { failConnection(); return }
        trace("Refreshing runtime snapshot")
        guard send(resolved, "SubscribeRuntimeInfo", call: runtimeCall) else { failConnection(); return }
        for id in [11, 13, 22] { readSetting(id) }
    }

    func writeSetting(_ id: Int, value: Int) -> Bool {
        guard let resolved, [11, 13, 22].contains(id),
              (id == 13 ? (1...4).contains(value) : (0...1).contains(value)) else { return false }
        nextCall &+= 1
        let call = nextCall
        writes[call] = id
        let sent = send(resolved, "WriteSetting", call: call, payload: MaestroWire.settingValue(id, value: value))
        if !sent { writes.removeValue(forKey: call) }
        return sent
    }
    private func readSetting(_ id: Int) {
        guard let resolved else { return }
        send(resolved, "ReadSetting", call: UInt32(100 + id), payload: [0x20] + MaestroWire.varint(UInt64(id)))
    }
    @discardableResult
    private func send(_ id: UInt32, _ method: String, call: UInt32, payload: [UInt8] = [], type: UInt32 = 0, status: UInt32 = 0) -> Bool {
        guard let channel, channel.isOpen() else { return false }
        let bytes = MaestroWire.request(channel: id, method: method, call: call, payload: payload, type: type, status: status)
        nextWriteID &+= 1
        let writeID = nextWriteID
        pendingWrites[writeID] = RFCOMMWriteBuffer(bytes)
        outbound.append(writeID)
        pumpWrites()
        return true
    }

    private func pumpWrites() {
        guard inFlightWrite == nil, let channel, channel.isOpen(), !channel.isTransmissionPaused(),
              let writeID = outbound.first, let payload = pendingWrites[writeID] else { return }
        outbound.removeFirst()
        inFlightWrite = writeID
        let currentSession = session
        let recovery = onTransportHang
        // IOBluetooth's asynchronous API can itself block the main run loop
        // after a stale socket reopen. Its deadline must run outside that loop.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [payload] in
            guard payload.deadline.isPending else { return }
            recovery?()
        }
        let result = channel.writeAsync(payload.pointer, length: UInt16(payload.count), refcon: UnsafeMutableRawPointer(bitPattern: writeID))
        trace("Bluetooth async write \(writeID): \(result)")
        guard result == kIOReturnSuccess else {
            payload.deadline.finish()
            failConnection()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.session == currentSession, self.inFlightWrite == writeID else { return }
            self.trace("Bluetooth write timed out; reconnecting")
            self.failConnection()
        }
    }

    func rfcommChannelFlowControlChanged(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        if rfcommChannel == channel { pumpWrites() }
    }
    func rfcommChannelQueueSpaceAvailable(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        if rfcommChannel == channel { pumpWrites() }
    }
    func rfcommChannelWriteComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, refcon: UnsafeMutableRawPointer!, status error: IOReturn) {
        guard rfcommChannel == channel, let refcon else { return }
        let writeID = UInt(bitPattern: refcon)
        guard let completed = pendingWrites.removeValue(forKey: writeID) else { return }
        completed.deadline.finish()
        if inFlightWrite == writeID { inFlightWrite = nil }
        trace("Bluetooth write completed: \(error)")
        if error != kIOReturnSuccess { failConnection() }
        else { pumpWrites() }
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        guard rfcommChannel == channel else { return }
        disconnect()
        onFailure?()
    }
    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        guard rfcommChannel == channel, let dataPointer else { return }
        for byte in UnsafeBufferPointer(start: dataPointer.assumingMemoryBound(to: UInt8.self), count: dataLength) {
            if byte == 0x7e {
                let frame = buffer
                buffer = []; escaped = false
                if !frame.isEmpty { receiveFrame(frame) }
            } else if byte == 0x7d {
                escaped = true
            } else {
                buffer.append(escaped ? byte ^ 0x20 : byte)
                escaped = false
                if buffer.count > 16384 { buffer = [] }
            }
        }
    }
    private func trace(_ text: String) { if CommandLine.arguments.contains("--diagnose") || CommandLine.arguments.contains("--diagnose-ui") { print(text) } }
    private func receiveFrame(_ frame: [UInt8]) {
        trace("Maestro frame: \(frame.count) bytes")
        guard frame.count >= 7 else { return }
        let content = Array(frame.dropLast(4))
        let checksum = frame.suffix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
        guard MaestroWire.crc(content) == checksum,
              let addressEnd = content.firstIndex(where: { $0 & 1 != 0 }),
              addressEnd < 5, addressEnd + 1 < content.count,
              content[addressEnd + 1] == 3,
              let packet = MaestroWire.fields(Array(content.dropFirst(addressEnd + 2))),
              packet[3]?.number == UInt64(MaestroWire.hash("maestro_pw.Maestro")) else { return }
        let method = packet[4]?.number
        let status = packet[6]?.number ?? 0
        if method == UInt64(MaestroWire.hash("SubscribeRuntimeInfo")) {
            trace("Runtime response type \(packet[1]?.number ?? 0), call \(packet[7]?.number ?? 0), expected \(runtimeCall), status \(status)")
        }
        if packet[2]?.number == resolved.map(UInt64.init),
           method == UInt64(MaestroWire.hash("WriteSetting")),
           let call = packet[7]?.number, call <= UInt32.max,
           let setting = writes.removeValue(forKey: UInt32(call)) {
            if status == 0 && packet[1]?.number == 1 { readSetting(setting) }
            else { onWriteFailure?(setting, "The earbuds rejected this change (Bluetooth status \(status)).") }
        }
        if method == UInt64(MaestroWire.hash("SubscribeRuntimeInfo")),
           packet[2]?.number == resolved.map(UInt64.init), packet[7]?.number == UInt64(runtimeCall),
           status != 0 || packet[1]?.number == 1 || packet[1]?.number == 5 {
            trace("Runtime stream ended; reconnecting")
            failConnection()
            return
        }
        guard status == 0 else { return }
        if method == UInt64(MaestroWire.hash("GetSoftwareInfo")), packet[1]?.number == 1, resolved == nil,
           let channelID = packet[2]?.number, channelID <= UInt32.max {
            resolved = UInt32(channelID)
            runtimeCall = 2
            runtimeWatchdog.requested()
            send(UInt32(channelID), "SubscribeRuntimeInfo", call: runtimeCall)
            send(UInt32(channelID), "SubscribeToSettingsChanges", call: 3)
            for id in [11, 13, 22] { readSetting(id) }
        }
        if packet[2]?.number == resolved.map(UInt64.init),
           (method == UInt64(MaestroWire.hash("ReadSetting")) && packet[1]?.number == 1 ||
            method == UInt64(MaestroWire.hash("SubscribeToSettingsChanges")) && packet[1]?.number == 7),
           let payload = packet[5]?.bytes {
            for (id, value) in MaestroWire.settings(payload) {
                trace("Setting \(id): \(value)")
                onSetting?(id, value)
            }
        }
        guard method == UInt64(MaestroWire.hash("SubscribeRuntimeInfo")), packet[1]?.number == 7,
              packet[2]?.number == resolved.map(UInt64.init), packet[7]?.number == UInt64(runtimeCall),
              let payload = packet[5]?.bytes, let runtime = MaestroWire.fields(payload) else { return }
        runtimeWatchdog.received()
        if let placement = MaestroWire.placement(payload) {
            onPlacement?(placement.leftInCase, placement.rightInCase)
        }
        guard let battery = runtime[6]?.bytes, let parts = MaestroWire.fields(battery) else { return }
        trace("Runtime battery fields: \(battery.map { String(format: "%02x", $0) }.joined())")
        func reading(_ id: Int) -> BatteryReading {
            guard let bytes = parts[id]?.bytes, let info = MaestroWire.fields(bytes) else { return BatteryReading(0x7f) }
            let state = info[2]?.number ?? 0
            guard info[1] != nil || state == 1 || state == 2 else { return BatteryReading(0x7f) }
            let level = info[1]?.number ?? 0
            guard level <= 100 else { return BatteryReading(0x7f) }
            return BatteryReading(UInt8(level) | (state == 2 ? 0x80 : 0))
        }
        onBattery?(reading(2), reading(3), reading(1))
    }
}
