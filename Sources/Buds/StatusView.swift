import AppKit
import SwiftUI
import ServiceManagement

final class AppPreferences: ObservableObject {
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var loginError: String?
}

struct StatusView: View {
    @ObservedObject var store: BudsStore
    @StateObject private var preferences = AppPreferences()
    private let accent = Color.accentColor

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                PixelBudsArtwork(name: "case")
                    .padding(3)
                    .frame(width: 36, height: 36)
                    .glassEffect(.regular, in: .rect(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.name).font(.system(size: 18, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Circle().fill(store.connected ? Color.green : Color.secondary).frame(width: 5, height: 5)
                        Text(store.connected ? "Connected" : "Not connected")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Menu {
                    if !store.devices.isEmpty {
                        Section("Earbuds") {
                            ForEach(store.devices, id: \.addressString) { device in
                                Button(device.name ?? "Pixel Buds") { store.select(device.addressString) }
                            }
                        }
                    }
                    Toggle("Open at Login", isOn: $preferences.launchAtLogin)
                        .onChange(of: preferences.launchAtLogin) { _, enabled in
                            do {
                                if enabled { try SMAppService.mainApp.register() }
                                else { try SMAppService.mainApp.unregister() }
                            } catch {
                                preferences.launchAtLogin = SMAppService.mainApp.status == .enabled
                                preferences.loginError = error.localizedDescription
                            }
                        }
                    Button("Bluetooth Settings…") { openBluetooth() }
                    Divider()
                    Button("Quit Buds", role: .destructive) { NSApp.terminate(nil) }.keyboardShortcut("q")
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold))
                        .frame(width: 28, height: 28).contentShape(Circle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Devices and settings")
            }

            HStack(spacing: 10) {
                battery("Left", artwork: "left_bud", reading: store.left, lastReported: store.leftStatus.isLastReported)
                battery("Case", artwork: "case", reading: store.caseBattery, lastReported: store.caseStatus.isLastReported)
                battery("Right", artwork: "right_bud", reading: store.right, lastReported: store.rightStatus.isLastReported)
            }
            .opacity(store.connected ? 1 : 0.5)

            settingsControls

            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: store.receiving ? "wave.3.right" : "info.circle")
                        .foregroundStyle(store.receiving ? accent : .secondary)
                    Text(store.message)
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                if store.caseStatus.isLastReported, let date = store.caseStatus.reportedAt {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text("Case last reported \(Text(date, style: .relative)) ago.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                } else if store.receiving {
                    Text("Case level updates when available.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)

            HStack(spacing: 10) {
                Button {
                    store.openWebSettings()
                } label: {
                    Label("Pixel Buds settings", systemImage: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.glass)
                .help("Open Google's web companion app")
                Button { store.reconnect() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .medium))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.glass).buttonBorderShape(.circle)
                .help("Refresh battery connection")
                .accessibilityLabel("Refresh battery connection")
            }
            if !store.connected {
                Button("Open Bluetooth Settings") { openBluetooth() }
                    .font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(accent)
            }
        }
        .padding(16)
        .frame(width: 360)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .padding(12)
        .alert("Couldn’t update login setting", isPresented: Binding(get: { preferences.loginError != nil }, set: { if !$0 { preferences.loginError = nil } })) {
            Button("OK") { preferences.loginError = nil }
        } message: { Text(preferences.loginError ?? "") }
    }

    private var settingsControls: some View {
        VStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Noise control", systemImage: "waveform")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if store.pendingSettings.contains(13) { ProgressView().controlSize(.mini) }
                }
                HStack(spacing: 5) {
                    noiseMode("Cancel", accessibility: "Noise Cancellation", symbol: "ear.badge.waveform", value: 2)
                    noiseMode("Off", accessibility: "Noise control off", symbol: "ear", value: 1)
                    noiseMode("Adaptive", accessibility: "Adaptive", symbol: "sparkles", value: 4)
                    noiseMode("Transparency", accessibility: "Transparency", symbol: "wave.3.right", value: 3)
                }
            }
            .padding(10)
            .background(.primary.opacity(0.035), in: .rect(cornerRadius: 15))

            VStack(spacing: 10) {
                settingToggle("Conversation detection", subtitle: "Pause media when you talk", symbol: "person.wave.2", id: 22)
                Divider().opacity(0.4)
                settingToggle("Multipoint", subtitle: "Connect to two devices", symbol: "point.3.connected.trianglepath.dotted", id: 11)
            }
            .padding(10)
            .background(.primary.opacity(0.035), in: .rect(cornerRadius: 15))

            if let error = store.settingsError {
                Text(error).font(.system(size: 11)).foregroundStyle(.orange)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            } else if store.receiving && store.settings.isEmpty {
                Text(store.settingsReconnecting ? "Settings are reconnecting…" : "Settings unavailable on this Bluetooth connection.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private func noiseMode(_ title: String, accessibility: String, symbol: String, value: Int) -> some View {
        let selected = store.settings[13] == value
        return Button { store.changeSetting(13, to: value) } label: {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 16))
                Text(title).font(.system(size: 10, weight: .medium))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 9)
            .foregroundStyle(selected ? accent : Color.primary)
            .background(selected ? accent.opacity(0.16) : Color.primary.opacity(0.045), in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? accent.opacity(0.6) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!store.connected || store.settings[13] == nil || !store.pendingSettings.isEmpty)
        .accessibilityLabel(accessibility)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(accessibility)
    }

    private func settingToggle(_ title: String, subtitle: String, symbol: String, id: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if store.pendingSettings.contains(id) { ProgressView().controlSize(.mini) }
            Toggle(title, isOn: Binding(get: { store.settings[id] == 1 }, set: { store.changeSetting(id, to: $0 ? 1 : 0) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(accent)
                .disabled(!store.connected || store.settings[id] == nil || !store.pendingSettings.isEmpty)
        }
    }

    private func battery(_ title: String, artwork: String, reading: BatteryReading, lastReported: Bool = false) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(.primary.opacity(0.06), lineWidth: 3)
                if let percent = reading.percent {
                    Circle().trim(from: 0, to: Double(percent) / 100)
                        .stroke(percent <= 20 ? Color.orange : accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                PixelBudsArtwork(name: artwork).frame(width: 46, height: 46)
            }.frame(width: 60, height: 60)
            Text(lastReported ? "\(title) · last reported" : title)
                .font(.system(size: lastReported ? 9 : 11, weight: .medium)).foregroundStyle(.secondary)
            HStack(spacing: 3) {
                if reading.charging { Image(systemName: "bolt.fill").font(.system(size: 10)).foregroundStyle(.green) }
                Text(reading.label).font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit()
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.primary.opacity(0.035), in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(reading.percent == nil ? "unavailable" : reading.label)\(reading.charging ? ", charging" : "")\(lastReported ? ", last reported" : "")")
    }

    private func openBluetooth() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
    }
}
