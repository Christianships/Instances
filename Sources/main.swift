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
    /// Keeps the panel matched to the pill, whose labels change every second.
    private var followTimer: Timer?

    private let height: CGFloat = 540
    /// Width when the SketchyBar pill can't be found.
    private let fallbackWidth: CGFloat = 260
    /// Gap between the bottom of the pill and the top of the panel.
    private let gap: CGFloat = 6
    /// The bracket around temp · gpu · cpu · mem in sketchybar/items/system.sh.
    private let barItem = "system"

    func applicationDidFinishLaunching(_ note: Notification) {
        let size = NSSize(width: fallbackWidth, height: height)
        panel = Panel(contentRect: NSRect(origin: .zero, size: size),
                      styleMask: [.borderless, .nonactivatingPanel],
                      backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        // No AppKit fade in or out: the panel appears and vanishes on the click.
        panel.animationBehavior = .none
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

    /// The pill's frame as SketchyBar reports it: top-left origin, in points,
    /// relative to its display. Asked fresh on every open because the pill
    /// grows and shrinks with its labels.
    private func pillRect() -> CGRect? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/sketchybar")
        p.arguments = ["--query", barItem]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rects = json["bounding_rects"] as? [String: [String: [Double]]],
              let r = rects.values.first,
              let o = r["origin"], let s = r["size"], o.count == 2, s.count == 2, s[0] > 0
        else { return nil }
        return CGRect(x: o[0], y: o[1], width: s[0], height: s[1])
    }

    private func place() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
        let f = screen.frame
        let frame: NSRect
        if let pill = pillRect() {
            frame = NSRect(x: f.minX + pill.minX, y: f.maxY - pill.maxY - gap - height,
                           width: pill.width, height: height)
        } else {
            let x = min(max(mouse.x - fallbackWidth / 2, f.minX + 8), f.maxX - fallbackWidth - 8)
            frame = NSRect(x: x, y: f.maxY - 42 - height, width: fallbackWidth, height: height)
        }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    func show() {
        place()
        followTimer?.invalidate()
        followTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.place() }
        store.optionDown = NSEvent.modifierFlags.contains(.option)
        store.openCount += 1
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // Sampling every process takes a moment, so the panel goes up first
        // with the last reading and refreshes on the next pass of the run loop.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.store.start()
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        followTimer?.invalidate()
        followTimer = nil
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
