import AppKit
import Combine

/// A running app plus everything it spawned (browser helpers, renderers,
/// shells in a terminal), rolled up so the numbers reflect its real cost.
struct AppEntry: Identifiable {
    let app: NSRunningApplication
    let pid: pid_t
    let name: String
    let isBackground: Bool
    var memory: UInt64
    var cpu: Double
    var gpu: Double
    var helpers: Int
    var windows: Int
    /// 1-based position among instances of the same app, when there are several.
    var instance = 0
    var instanceCount = 1
    var id: pid_t { pid }
    var groupKey: String { app.bundleIdentifier ?? name }
}

enum SortKey { case memory, cpu, gpu, name }

/// Processes that take the session down with them. Their kill buttons are
/// disabled rather than hidden so it is clear why nothing happens.
let protectedNames: Set<String> = ["launchd", "kernel_task", "WindowServer", "loginwindow"]

/// macOS's own UI agents (loginwindow, Control Center, Notification Center,
/// Dock...). Quitting them breaks the session or they respawn at once, so
/// they only appear in the Processes tab. Finder is the one worth quitting.
private func isSystemAgent(_ app: NSRunningApplication) -> Bool {
    guard let path = app.bundleURL?.path else { return false }
    return path.hasPrefix("/System/Library/CoreServices/") && app.bundleIdentifier != "com.apple.finder"
}

final class Store: ObservableObject {
    @Published var apps: [AppEntry] = []
    @Published var procs: [Proc] = []
    @Published var optionDown = false
    @Published var status: String?
    /// Bumped each time the panel opens so the search field grabs focus.
    @Published var openCount = 0

    private let sampler = Sampler()
    private var timer: Timer?
    private var statusClear: DispatchWorkItem?

    func start() {
        refresh()
        // Second reading shortly after so CPU numbers appear almost at once.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.refresh() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let procs = sampler.sample()
        var byPid: [pid_t: Proc] = [:]
        var children: [pid_t: [pid_t]] = [:]
        for p in procs {
            byPid[p.pid] = p
            if p.ppid != p.pid { children[p.ppid, default: []].append(p.pid) }
        }

        let me = getpid()
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != me && !$0.isTerminated && $0.activationPolicy != .prohibited
                && !isSystemAgent($0)
        }
        let appPids = Set(running.map(\.processIdentifier))
        let windows = windowCounts()

        var entries: [AppEntry] = []
        for app in running {
            let pid = app.processIdentifier
            let own = byPid[pid]
            var mem = own?.memory ?? 0
            var cpu = own?.cpu ?? 0
            var gpu = own?.gpu ?? 0
            var helpers = 0
            var seen: Set<pid_t> = [pid]
            var stack = children[pid] ?? []
            while let c = stack.popLast() {
                // Another app launched from this one keeps its own row.
                guard seen.insert(c).inserted, !appPids.contains(c) else { continue }
                if let p = byPid[c] {
                    mem += p.memory
                    cpu += p.cpu
                    gpu += p.gpu
                    helpers += 1
                }
                stack += children[c] ?? []
            }
            entries.append(AppEntry(
                app: app,
                pid: pid,
                name: app.localizedName ?? own?.name ?? "pid \(pid)",
                isBackground: app.activationPolicy != .regular,
                memory: mem,
                cpu: cpu,
                gpu: min(gpu, 100),
                helpers: helpers,
                windows: windows[pid] ?? 0
            ))
        }

        let groups = Dictionary(grouping: entries.indices, by: { entries[$0].groupKey })
        for (_, idx) in groups where idx.count > 1 {
            for (n, i) in idx.sorted(by: { entries[$0].pid < entries[$1].pid }).enumerated() {
                entries[i].instance = n + 1
                entries[i].instanceCount = idx.count
            }
        }

        self.apps = entries
        self.procs = procs
    }

    // MARK: actions

    func activate(_ e: AppEntry) {
        if e.app.isHidden { e.app.unhide() }
        e.app.activate(options: [.activateAllWindows])
    }

    func quit(_ e: AppEntry, force: Bool) {
        let ok = force ? e.app.forceTerminate() : e.app.terminate()
        flash(ok ? "\(force ? "Force quit" : "Quit") \(e.name)" : "\(e.name) refused to quit")
        refreshSoon()
    }

    func quitAllInstances(of e: AppEntry, force: Bool) {
        for other in apps where other.groupKey == e.groupKey {
            _ = force ? other.app.forceTerminate() : other.app.terminate()
        }
        flash("Quit all \(e.name) instances")
        refreshSoon()
    }

    func kill(_ p: Proc, force: Bool) {
        guard !protectedNames.contains(p.name) else { return }
        if Darwin.kill(p.pid, force ? SIGKILL : SIGTERM) == 0 {
            flash("Sent \(force ? "SIGKILL" : "SIGTERM") to \(p.name) (\(p.pid))")
        } else {
            flash(errno == EPERM ? "Not allowed to kill \(p.name) -- owned by another user"
                                 : "Could not kill \(p.name): \(String(cString: strerror(errno)))")
        }
        refreshSoon()
    }

    private func refreshSoon() {
        for delay in [0.5, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.refresh() }
        }
    }

    private func flash(_ text: String) {
        status = text
        statusClear?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.status = nil }
        statusClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
}
