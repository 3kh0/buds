import AppKit
import SwiftUI
import Darwin

@main
struct BudsApp {
    static func main() {
        if CommandLine.arguments.contains("--relaunch-delay") { Thread.sleep(forTimeInterval: 3.2) }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class BudsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = BudsStore()
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var outsideMonitor: Any?
    private var localMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--diagnose") {
            store.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [self] in
                print("Device: \(store.name)\nConnected: \(store.connected)\nLive stream: \(store.receiving)\nLeft: \(store.left.label)\nRight: \(store.right.label)\nCase: \(store.caseBattery.label)\nMenu bar: \(store.menuBarSelection), \(store.menuBarBattery.map { "\($0)%" } ?? "unavailable")\nPlacement: left in case \(String(describing: store.leftInCase)), right in case \(String(describing: store.rightInCase))\nStatus: \(store.message)")
                NSApp.terminate(nil)
            }
            return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = PixelArtwork.menuBarImage()
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePanel)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        panel = BudsPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovable = false
        panel.contentView = NSHostingView(rootView: StatusView(store: store))
        store.onChange = { [weak self] in self?.updateStatus() }
        store.onTransportHang = { TransportRecovery.relaunch() }
        store.start()
        updateStatus()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }
            if event.type == .keyDown && event.keyCode == 53 { self.hidePanel(); return nil }
            if event.type != .keyDown && event.window != self.panel && event.window != self.statusItem.button?.window { self.hidePanel() }
            return event
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(hidePanel), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.togglePanel() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) { store.stop() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if panel != nil && !panel.isVisible { togglePanel() }
        return true
    }

    private func updateStatus() {
        statusItem?.button?.image = PixelArtwork.menuBarImage(for: store.menuBarSelection)
        let selectionLabel: String
        switch store.menuBarSelection {
        case .left: selectionLabel = "Left earbud"
        case .right: selectionLabel = "Right earbud"
        case .both: selectionLabel = "Both earbuds"
        case .none: selectionLabel = "Pixel Buds"
        }
        statusItem?.button?.setAccessibilityLabel(selectionLabel)
        statusItem?.button?.setAccessibilityValue(store.menuBarBattery.map { "\($0)%" } ?? "Battery unavailable")
        statusItem?.button?.title = store.menuBarBattery.map { " \($0)%" } ?? ""
        statusItem?.button?.toolTip = "\(store.name) · \(store.connected ? "Left \(store.left.label) · Right \(store.right.label) · Case \(store.caseBattery.label)" : "Not connected")"
    }

    @objc private func togglePanel() {
        if panel.isVisible { hidePanel(); return }
        guard let button = statusItem.button, let window = button.window else { return }
        store.refresh()
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let size = panel.contentView!.fittingSize
        let screen = window.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        let x = max(screen.minX + 8, min(anchor.midX - size.width / 2, screen.maxX - size.width - 8))
        panel.setFrame(NSRect(x: x, y: anchor.minY - size.height - 2, width: size.width, height: size.height), display: true)
        panel.makeKeyAndOrderFront(nil)
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.hidePanel() }
    }

    @objc private func hidePanel() {
        panel.orderOut(nil)
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor); self.outsideMonitor = nil }
    }
}

private enum TransportRecovery {
    private static let lock = NSLock()
    private static var restarting = false
    static func relaunch() {
        let shouldRestart = lock.withLock {
            if restarting { return false }
            restarting = true
            return true
        }
        guard shouldRestart, let executable = Bundle.main.executableURL else { return }
        let replacement = Process()
        replacement.executableURL = executable
        replacement.standardInput = FileHandle.nullDevice
        replacement.standardOutput = FileHandle.nullDevice
        replacement.standardError = FileHandle.nullDevice
        replacement.arguments = ["--relaunch-delay"] + (CommandLine.arguments.contains("--show") ? ["--show"] : [])
        do {
            try replacement.run()
            _exit(0)
        } catch {
            lock.withLock { restarting = false }
        }
    }
}
