import AppKit
import SwiftUI

/// Borderless panels refuse key status by default; the search field needs it.
final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { (NSApp.delegate as? AppDelegate)?.hide() }
}

/// Windowless app that owns one floating panel. `open -a Instances` (the
/// SketchyBar click) launches it the first time and toggles the panel after.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = Store()
    private var panel: Panel!
    private var hiddenAt = Date.distantPast

    private let size = NSSize(width: 480, height: 580)
    /// Bar is 32pt tall with a 3pt y_offset; leave a small gap below it.
    private let topInset: CGFloat = 42

    func applicationDidFinishLaunching(_ note: Notification) {
        panel = Panel(contentRect: NSRect(origin: .zero, size: size),
                      styleMask: [.borderless, .nonactivatingPanel],
                      backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.delegate = self

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .darkAqua)
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        let host = NSHostingView(rootView: RootView(store: store, dismiss: { [weak self] in self?.hide() }))
        host.frame = effect.bounds
        host.autoresizingMask = [.width, .height]
        effect.addSubview(host)
        panel.contentView = effect

        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            self?.store.optionDown = e.modifierFlags.contains(.option)
            return e
        }

        show()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Clicking the bar can make the panel resign key (and hide) a moment
        // before this reopen arrives; treat that pair as a single "close".
        if panel.isVisible { hide() }
        else if Date().timeIntervalSince(hiddenAt) > 0.4 { show() }
        return false
    }

    func show() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
        let f = screen.frame
        let x = min(max(mouse.x - size.width / 2, f.minX + 8), f.maxX - size.width - 8)
        let y = f.maxY - topInset - size.height
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)

        store.optionDown = NSEvent.modifierFlags.contains(.option)
        store.start()
        store.openCount += 1
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        store.stop()
        hiddenAt = Date()
    }

    func windowDidResignKey(_ notification: Notification) { hide() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
