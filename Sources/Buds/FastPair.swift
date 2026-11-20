import Foundation

struct BatteryReading: Equatable {
    let percent: Int?
    let charging: Bool

    init(_ byte: UInt8) {
        let value = Int(byte & 0x7f)
        percent = value <= 100 ? value : nil
        charging = percent != nil && byte & 0x80 != 0
    }
    var label: String { percent.map { "\($0)%" } ?? "—" }
}

/// Keep the last measured percentage when a component stops reporting.
/// Charging is meaningful only for a live report.
struct BatteryStatus: Codable {
    private(set) var lastPercent: Int?
    private(set) var reportedAt: Date?
    private var liveReading: BatteryReading? = nil
    private enum CodingKeys: String, CodingKey { case lastPercent, reportedAt }

    var isLastReported: Bool { lastPercent != nil && liveReading == nil }
    var reading: BatteryReading { liveReading ?? BatteryReading(lastPercent.map(UInt8.init) ?? 0x7f) }

    mutating func receive(_ reading: BatteryReading, at date: Date = Date()) {
        guard let percent = reading.percent else { markUnavailable(); return }
        lastPercent = percent
        reportedAt = date
        liveReading = reading
    }

    mutating func markUnavailable() { liveReading = nil }
}

struct FastPairMessage: Equatable {
    let group: UInt8
    let code: UInt8
    let payload: [UInt8]
}

/// RFCOMM is a byte stream: a callback can contain part of a frame or many frames.
struct FastPairDecoder {
    private var buffer: [UInt8] = []
    mutating func reset() { buffer.removeAll() }
    mutating func receive(_ bytes: [UInt8]) throws -> [FastPairMessage] {
        buffer.append(contentsOf: bytes)
        var messages: [FastPairMessage] = []
        while buffer.count >= 4 {
            let count = Int(buffer[2]) << 8 | Int(buffer[3])
            guard count <= 4096 else {
                reset()
                throw CocoaError(.coderReadCorrupt)
            }
            guard buffer.count >= count + 4 else { break }
            messages.append(.init(group: buffer[0], code: buffer[1], payload: Array(buffer[4..<(4 + count)])))
            buffer.removeFirst(4 + count)
        }
        return messages
    }
}

enum EarbudSelection {
    case left, right, both, none

    static func active(left: BatteryStatus, right: BatteryStatus, leftInCase: Bool?, rightInCase: Bool?) -> Self {
        func isActive(_ status: BatteryStatus, inCase: Bool?) -> Bool {
            guard status.reading.percent != nil, !status.isLastReported, !status.reading.charging else { return false }
            return inCase != true
        }
        switch (isActive(left, inCase: leftInCase), isActive(right, inCase: rightInCase)) {
        case (true, false): return .left
        case (false, true): return .right
        case (true, true): return .both
        case (false, false): return .none
        }
    }
}

struct RuntimeWatchdog {
    enum Action { case none, renew, reconnect }
    private var requestedAt: Date
    private var receivedAt: Date?

    init(now: Date = Date()) { requestedAt = now }
    mutating func requested(at date: Date = Date()) { requestedAt = date; receivedAt = nil }
    mutating func received(at date: Date = Date()) { receivedAt = date }
    func action(at date: Date = Date()) -> Action {
        if receivedAt == nil { return date.timeIntervalSince(requestedAt) >= 8 ? .reconnect : .none }
        return date.timeIntervalSince(requestedAt) >= 15 ? .renew : .none
    }
}

/// Checked from a background queue as well as the Bluetooth callback thread.
final class WriteDeadline {
    private let lock = NSLock()
    private var pending = true
    var isPending: Bool { lock.withLock { pending } }
    func finish() { lock.withLock { pending = false } }
}
