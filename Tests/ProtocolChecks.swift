import Foundation

func XCTAssertTrue(_ condition: @autoclosure () throws -> Bool) rethrows {
    let value = try condition()
    precondition(value, "Protocol check failed")
}
func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T) {
    do { _ = try expression(); fatalError("Expected malformed frame to throw") } catch { }
}

@main
struct ProtocolChecks {
    static func main() throws {
        let checks = ProtocolChecks()
        checks.testBatteryValues()
        checks.testRuntimeWatchdog()
        let write = WriteDeadline()
        XCTAssertTrue(write.isPending)
        write.finish()
        XCTAssertTrue(!write.isPending)
        checks.testActiveEarbuds()
        checks.testSettingsWireFormat()
        try checks.testCaseBatteryRetention()
        try checks.testFragmentedAndCoalescedFrames()
        try checks.testOversizedFrameResetsDecoder()
        precondition(MaestroWire.hash("maestro_pw.Maestro") == 0x7ede71ea)
        precondition(MaestroWire.hash("GetSoftwareInfo") == 0x7199fa44)
        precondition(MaestroWire.crc(Array("123456789".utf8)) == 0xcbf43926)
        precondition(MaestroWire.fields([0x32, 0xff]) == nil)
        print("Passed stream renewal and timeout recovery, active-earbud selection, battery retention and persistence, audio settings encoding, stream framing, bounds, RPC hash, CRC, and malformed protobuf checks.")
    }
    func testRuntimeWatchdog() {
        let start = Date(timeIntervalSince1970: 1000)
        var health = RuntimeWatchdog(now: start)
        XCTAssertTrue(health.action(at: start.addingTimeInterval(7)) == .none)
        XCTAssertTrue(health.action(at: start.addingTimeInterval(8)) == .reconnect)
        health.received(at: start.addingTimeInterval(1))
        XCTAssertTrue(health.action(at: start.addingTimeInterval(14)) == .none)
        XCTAssertTrue(health.action(at: start.addingTimeInterval(15)) == .renew)
        health.requested(at: start.addingTimeInterval(15))
        XCTAssertTrue(health.action(at: start.addingTimeInterval(22)) == .none)
        XCTAssertTrue(health.action(at: start.addingTimeInterval(23)) == .reconnect)
        health.received(at: start.addingTimeInterval(24))
        XCTAssertTrue(health.action(at: start.addingTimeInterval(25)) == .none)
        XCTAssertTrue(health.action(at: start.addingTimeInterval(30)) == .renew)
    }

    func testActiveEarbuds() {
        var left = BatteryStatus()
        var right = BatteryStatus()
        left.receive(BatteryReading(97))
        right.receive(BatteryReading(0x80 | 100))
        XCTAssertTrue(EarbudSelection.active(left: left, right: right, leftInCase: nil, rightInCase: nil) == .left)
        right.receive(BatteryReading(100))
        XCTAssertTrue(EarbudSelection.active(left: left, right: right, leftInCase: false, rightInCase: true) == .left)
        XCTAssertTrue(EarbudSelection.active(left: left, right: right, leftInCase: true, rightInCase: false) == .right)
        XCTAssertTrue(EarbudSelection.active(left: left, right: right, leftInCase: false, rightInCase: false) == .both)
        XCTAssertTrue(EarbudSelection.active(left: left, right: right, leftInCase: true, rightInCase: true) == .none)
        right.markUnavailable()
        XCTAssertTrue(EarbudSelection.active(left: left, right: right, leftInCase: false, rightInCase: false) == .left)
        XCTAssertTrue(right.reading.percent == 100 && right.isLastReported)
        XCTAssertTrue(EarbudSelection.active(left: left, right: right, leftInCase: nil, rightInCase: nil) == .left)
        left.markUnavailable()
        XCTAssertTrue(EarbudSelection.active(left: left, right: right, leftInCase: nil, rightInCase: nil) == .none)
        let placement = MaestroWire.placement([0x3a, 0x02, 0x08, 0x01])
        XCTAssertTrue(placement?.rightInCase == true && placement?.leftInCase == false)
        let bothOut = MaestroWire.placement([0x3a, 0x00])
        XCTAssertTrue(bothOut?.leftInCase == false && bothOut?.rightInCase == false)
        XCTAssertTrue(MaestroWire.placement([]) == nil)
    }

    func testSettingsWireFormat() {
        XCTAssertTrue(MaestroWire.settingValue(13, value: 4) == [0x22, 0x02, 0x68, 0x04])
        XCTAssertTrue(MaestroWire.settingValue(11, value: 0) == [0x22, 0x02, 0x58, 0x00])
        XCTAssertTrue(MaestroWire.settingValue(22, value: 1) == [0x22, 0x03, 0xb0, 0x01, 0x01])
        XCTAssertTrue(MaestroWire.settings([0x22, 0x02, 0x58, 0x00]) == [11: 0])
        XCTAssertTrue(MaestroWire.settings([0x22, 0x03, 0xb0, 0x01, 0x01]) == [22: 1])
        XCTAssertTrue(MaestroWire.settings([0x22, 0x02, 0x68, 0x02]) == [13: 2])
        XCTAssertTrue(MaestroWire.settings([0x22, 0xff]).isEmpty)
    }

    func testCaseBatteryRetention() throws {
        var status = BatteryStatus()
        status.receive(BatteryReading(0x7f))
        XCTAssertTrue(status.reading.percent == nil && !status.isLastReported)
        let time = Date(timeIntervalSince1970: 1000)
        status.receive(BatteryReading(0x80 | 85), at: time)
        XCTAssertTrue(status.reading.percent == 85 && status.reading.charging && !status.isLastReported)
        let liveRestored = try JSONDecoder().decode(BatteryStatus.self, from: JSONEncoder().encode(status))
        XCTAssertTrue(liveRestored.reading.percent == 85 && liveRestored.isLastReported && !liveRestored.reading.charging)
        status.receive(BatteryReading(0xff))
        XCTAssertTrue(status.reading.percent == 85 && !status.reading.charging && status.isLastReported)
        XCTAssertTrue(status.reportedAt == time)
        let restored = try JSONDecoder().decode(BatteryStatus.self, from: JSONEncoder().encode(status))
        XCTAssertTrue(restored.reading.percent == 85 && restored.isLastReported && restored.reportedAt == time)
        status.receive(BatteryReading(84))
        XCTAssertTrue(status.reading.percent == 84 && !status.isLastReported)
        status.markUnavailable()
        XCTAssertTrue(status.reading.percent == 84 && status.isLastReported)
        XCTAssertTrue(BatteryStatus().reading.percent == nil)
    }

    func testBatteryValues() {
        XCTAssertTrue(BatteryReading(100).percent == 100)
        XCTAssertTrue(BatteryReading(0).percent == 0)
        XCTAssertTrue(BatteryReading(0x80 | 86).charging)
        XCTAssertTrue(BatteryReading(0x80 | 86).percent == 86)
        XCTAssertTrue(BatteryReading(0x7f).percent == nil)
        XCTAssertTrue(BatteryReading(0xff).percent == nil)
        XCTAssertTrue(!BatteryReading(0xff).charging)
        XCTAssertTrue(BatteryReading(101).percent == nil)
    }

    func testFragmentedAndCoalescedFrames() throws {
        var decoder = FastPairDecoder()
        try XCTAssertTrue(try decoder.receive([3, 3, 0]).isEmpty)
        try XCTAssertTrue(try decoder.receive([3, 100]).isEmpty)
        let messages = try decoder.receive([0xe4, 86, 3, 1, 0, 3, 1, 2, 3])
        XCTAssertTrue(messages == [
            FastPairMessage(group: 3, code: 3, payload: [100, 0xe4, 86]),
            FastPairMessage(group: 3, code: 1, payload: [1, 2, 3])
        ])
    }

    func testOversizedFrameResetsDecoder() throws {
        var decoder = FastPairDecoder()
        XCTAssertThrowsError(try decoder.receive([3, 3, 0xff, 0xff]))
        try XCTAssertTrue(try decoder.receive([3, 3, 0, 3, 100, 100, 86]).count == 1)
    }
}
