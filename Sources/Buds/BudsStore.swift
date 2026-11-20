import AppKit
import Combine
import IOBluetooth

final class BudsStore: NSObject, ObservableObject, IOBluetoothRFCOMMChannelDelegate {
    @Published var devices: [IOBluetoothDevice] = []
    @Published var selectedAddress: String? = UserDefaults.standard.string(forKey: "selectedDevice")
    @Published var name = "Pixel Buds"
    @Published var connected = false
    @Published var receiving = false
    @Published var message = "Looking for your earbuds…"
    @Published private(set) var leftStatus = BatteryStatus()
    @Published private(set) var rightStatus = BatteryStatus()
    @Published private(set) var caseStatus = BatteryStatus()
    @Published private(set) var leftInCase: Bool?
    @Published private(set) var rightInCase: Bool?
    var left: BatteryReading { leftStatus.reading }
    var right: BatteryReading { rightStatus.reading }
    var caseBattery: BatteryReading { caseStatus.reading }
    @Published private(set) var settings: [Int: Int] = [:]
    @Published private(set) var pendingSettings: Set<Int> = []
    @Published var settingsError: String?
    @Published private(set) var settingsReconnecting = false
    @Published var updated: Date?
    var onChange: (() -> Void)?
    var onTransportHang: (() -> Void)?
    private var channel: IOBluetoothRFCOMMChannel?
    private let maestro = MaestroBattery()
    private var maestroUpdated = false
    private var maestroUpdatedAt = Date.distantPast
    private var fastPairOpenedAt = Date.distantPast
    private var fastPairRetryAt = Date.distantPast
    private var pausedForWeb = false
    private var device: IOBluetoothDevice?
    private var decoder = FastPairDecoder()
    private var timer: Timer?
    private var attemptDate = Date.distantPast
    private var connectionReadyAt = Date.distantPast
    private var querying = false
    private var generation = 0
    private let serviceUUID = IOBluetoothSDPUUID(data: Data([0xdf, 0x21, 0xfe, 0x2c, 0x25, 0x15, 0x4f, 0xdb, 0x88, 0x86, 0xf1, 0x2c, 0x4d, 0x67, 0x92, 0x7c]))

    var menuBarSelection: EarbudSelection {
        guard connected else { return .none }
        return .active(left: leftStatus, right: rightStatus, leftInCase: leftInCase, rightInCase: rightInCase)
    }
    var menuBarBattery: Int? {
        switch menuBarSelection {
        case .left: return left.percent
        case .right: return right.percent
        case .both: return [left.percent, right.percent].compactMap { $0 }.min()
        case .none: return nil
        }
    }

    func start() {
        maestro.onTransportHang = onTransportHang
        maestro.onPlacement = { [weak self] left, right in
            self?.leftInCase = left
            self?.rightInCase = right
            self?.onChange?()
        }
        maestro.onSetting = { [weak self] id, value in
            self?.settingsReconnecting = false
            self?.settings[id] = value
            self?.pendingSettings.remove(id)
        }
        maestro.onWriteFailure = { [weak self] id, error in
            self?.pendingSettings.remove(id)
            self?.settingsError = error
        }
        maestro.onOpen = { [weak self] in
            guard let self else { return }
            let current = self.generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.generation == current, !self.pausedForWeb,
                      self.channel == nil, let device = self.device, device.isConnected() else { return }
                self.openFastPair(device)
            }
        }
        maestro.onFailure = { [weak self] in
            guard let self, !self.pausedForWeb else { return }
            self.maestroUpdated = false
            self.settings = [:]
            self.settingsReconnecting = true
            self.pendingSettings = []
            self.attemptDate = Date()
            self.fastPairRetryAt = Date().addingTimeInterval(3)
            if self.channel == nil && !self.receiving { self.message = "Reconnecting to battery updates…" }
        }
        maestro.onBattery = { [weak self] left, right, caseBattery in
            guard let self else { return }
            self.receiveBatteries(left: left, right: right, caseBattery: caseBattery)
            self.maestroUpdated = true
            self.maestroUpdatedAt = Date()
            self.receiving = true
            self.updated = Date()
            self.message = "Battery updates are live"
            self.onChange?()
        }
        refresh()
        timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer!, forMode: .common)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
    }
    func stop() {
        timer?.invalidate()
        timer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        onTransportHang = nil
        maestro.prepareForExit()
    }

    @objc private func woke() { reconnect() }

    func select(_ address: String) {
        guard selectedAddress != address else { return }
        selectedAddress = address
        UserDefaults.standard.set(address, forKey: "selectedDevice")
        disconnect()
        device = nil
        leftStatus = BatteryStatus()
        rightStatus = BatteryStatus()
        caseStatus = BatteryStatus()
        refresh()
    }

    func reconnect() {
        if !pausedForWeb, device?.isConnected() == true, maestro.isReady {
            maestro.refreshSnapshot()
            return
        }
        pausedForWeb = false
        disconnect()
        attemptDate = .distantPast
        message = "Reconnecting to your earbuds…"
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { [weak self] in
            guard let self, self.generation == current else { return }
            self.refresh()
        }
    }

    private func disconnect() {
        generation += 1
        connectionReadyAt = Date().addingTimeInterval(3)
        maestro.disconnect()
        maestroUpdated = false
        maestroUpdatedAt = .distantPast
        fastPairRetryAt = connectionReadyAt
        querying = false
        let old = channel
        channel = nil
        closeBluetoothChannel(old, onHang: onTransportHang)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { withExtendedLifetime(old) {} }
        receiving = false
        settings = [:]
        settingsReconnecting = false
        pendingSettings = []
        settingsError = nil
        decoder.reset()
        leftStatus.markUnavailable()
        rightStatus.markUnavailable()
        leftInCase = nil
        rightInCase = nil
        caseStatus.markUnavailable()
        updated = nil
        onChange?()
    }

    func changeSetting(_ id: Int, to value: Int) {
        guard connected, settings[id] != nil, pendingSettings.isEmpty else { return }
        settingsError = nil
        pendingSettings.insert(id)
        guard maestro.writeSetting(id, value: value) else {
            pendingSettings.remove(id)
            settingsError = "Couldn’t send this change. Refresh the Bluetooth connection and try again."
            return
        }
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.generation == current, self.pendingSettings.contains(id) else { return }
            self.pendingSettings.remove(id)
            self.settingsError = "The earbuds haven’t confirmed this change. Refresh to check their current settings."
        }
    }

    private func receiveBatteries(left: BatteryReading, right: BatteryReading, caseBattery: BatteryReading) {
        leftStatus.receive(left)
        rightStatus.receive(right)
        caseStatus.receive(caseBattery)
        guard let address = device?.addressString else { return }
        for (component, reading, status) in [("left", left, leftStatus), ("right", right, rightStatus), ("case", caseBattery, caseStatus)] {
            guard reading.percent != nil, let data = try? JSONEncoder().encode(status) else { continue }
            UserDefaults.standard.set(data, forKey: "\(component)Battery.\(address)")
        }
    }

    private func loadBattery(_ component: String, for address: String) -> BatteryStatus {
        guard let data = UserDefaults.standard.data(forKey: "\(component)Battery.\(address)"),
              let cached = try? JSONDecoder().decode(BatteryStatus.self, from: data),
              let percent = cached.lastPercent, (0...100).contains(percent),
              cached.reportedAt != nil else { return BatteryStatus() }
        return cached
    }

    func openWebSettings() {
        pausedForWeb = true
        disconnect()
        message = "Updates paused for the web app. Refresh to resume."
        NSWorkspace.shared.open(URL(string: "https://mypixelbuds.google.com/")!)
    }

    func refresh() {
        guard !pausedForWeb else { return }
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        devices = paired.filter {
            ($0.name ?? "").localizedCaseInsensitiveContains("bud") ||
            $0.getServiceRecord(for: serviceUUID) != nil ||
            $0.addressString == selectedAddress
        }.sorted { ($0.name ?? "") < ($1.name ?? "") }
        let candidate = devices.first { $0.addressString == selectedAddress }
            ?? devices.first { $0.isConnected() } ?? devices.first
        guard let candidate else {
            disconnect()
            device = nil
            leftStatus = BatteryStatus()
            rightStatus = BatteryStatus()
            caseStatus = BatteryStatus()
            connected = false
            message = "Pair your Pixel Buds in Bluetooth Settings to get started."
            onChange?()
            return
        }
        if device?.addressString != candidate.addressString {
            let replacingDevice = device != nil
            disconnect()
            if !replacingDevice { connectionReadyAt = .distantPast }
            device = candidate
            leftStatus = loadBattery("left", for: candidate.addressString)
            rightStatus = loadBattery("right", for: candidate.addressString)
            caseStatus = loadBattery("case", for: candidate.addressString)
            name = candidate.name ?? "Pixel Buds"
        }
        connected = candidate.isConnected()
        guard connected else {
            if channel != nil || maestro.isActive || querying || receiving { disconnect() }
            message = "Connect your earbuds to see their battery levels."
            onChange?()
            return
        }
        guard Date() >= connectionReadyAt else { return }
        if channel != nil && !maestroUpdated && Date().timeIntervalSince(fastPairOpenedAt) >= 30 {
            closeFastPair()
            fastPairRetryAt = Date().addingTimeInterval(3)
        }
        if channel == nil && Date() >= fastPairRetryAt && (maestro.isReady || !maestro.isActive && Date().timeIntervalSince(attemptDate) < 15) {
            openFastPair(candidate)
        }
        guard !maestro.isActive, !querying else { return }
        guard Date().timeIntervalSince(attemptDate) > 15 else { return }
        attemptDate = Date()
        if !receiving { message = "Connecting to battery updates…" }
        if settings.isEmpty { settingsReconnecting = true }
        querying = true
        let result = candidate.performSDPQuery(self)
        if result != kIOReturnSuccess {
            querying = false
            message = "Couldn’t read Bluetooth services. Try Refresh."
        }
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.generation == current, !self.receiving else { return }
            self.querying = false
            if !self.maestro.isActive && self.channel == nil, let device = self.device {
                self.openFastPair(device)
            }
            if !self.receiving { self.message = "Waiting for battery updates. Retrying automatically…" }
        }
        onChange?()
    }

    @objc func sdpQueryComplete(_ sender: IOBluetoothDevice!, status: IOReturn) {
        guard sender?.addressString == device?.addressString, querying else { return }
        querying = false
        guard status == kIOReturnSuccess else {
            message = "Couldn’t read Bluetooth services. Try Refresh."
            return
        }
        if !maestro.connect(sender) {
            settingsReconnecting = false
            openFastPair(sender)
        }
    }

    private func openFastPair(_ sender: IOBluetoothDevice) {
        guard let service = sender.getServiceRecord(for: serviceUUID) else {
            message = "Battery service unavailable. Connect your Pixel Buds and try again."
            return
        }
        var channelID: BluetoothRFCOMMChannelID = 0
        guard service.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else {
            message = "These earbuds don’t expose a Fast Pair battery stream."
            return
        }
        guard channel == nil, sender.isConnected(), !pausedForWeb else { return }
        fastPairOpenedAt = Date()
        let result = sender.openRFCOMMChannelAsync(&channel, withChannelID: channelID, delegate: self)
        if result == kIOReturnSuccess { _ = channel?.setDelegate(self) }
        if result != kIOReturnSuccess {
            channel = nil
            fastPairRetryAt = Date().addingTimeInterval(5)
            if !receiving { message = "Battery stream is busy. Retrying automatically…" }
        }
    }

    func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        guard channel == nil || rfcommChannel == channel else { return }
        channel = rfcommChannel
        if error != kIOReturnSuccess {
            channel = nil
            fastPairRetryAt = Date().addingTimeInterval(5)
            if !receiving { message = "Couldn’t open battery updates. Retrying automatically…" }
        }
    }

    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        guard rfcommChannel == channel, let dataPointer else { return }
        let bytes = Array(UnsafeBufferPointer(start: dataPointer.assumingMemoryBound(to: UInt8.self), count: dataLength))
        do {
            for frame in try decoder.receive(bytes) where (!maestroUpdated || Date().timeIntervalSince(maestroUpdatedAt) > 20) && frame.group == 3 && frame.code == 3 && frame.payload.count >= 3 {
                receiveBatteries(left: BatteryReading(frame.payload[0]), right: BatteryReading(frame.payload[1]), caseBattery: BatteryReading(frame.payload[2]))
                updated = Date()
                receiving = true
                message = "Battery updates are live"
                onChange?()
            }
        } catch {
            message = "Unexpected battery data. Try Refresh."
        }
    }

    private func closeFastPair() {
        let old = channel
        channel = nil
        closeBluetoothChannel(old, onHang: onTransportHang)
        decoder.reset()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { withExtendedLifetime(old) {} }
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        guard rfcommChannel == channel else { return }
        closeFastPair()
        fastPairRetryAt = Date().addingTimeInterval(3)
        if !maestroUpdated {
            receiving = false
            leftStatus.markUnavailable()
            rightStatus.markUnavailable()
            caseStatus.markUnavailable()
            message = "Battery stream closed. Reconnecting…"
            onChange?()
        }
    }
}
