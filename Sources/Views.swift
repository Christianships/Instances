import AppKit
import SwiftUI

// Palette mirrors sketchybar/colors.sh: monotone white at varying alpha,
// with red kept for the one thing worth shouting about.
private let fg = Color.white.opacity(0.95)
private let dim = Color.white.opacity(0.5)
private let faint = Color.white.opacity(0.08)
private let critical = Color(red: 1, green: 0.27, blue: 0.23)
private let cpuWidth: CGFloat = 38
private let gpuWidth: CGFloat = 32
private let memWidth: CGFloat = 54

private func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> Font {
    let w = weight == .semibold ? 8 : 5
    if let f = NSFontManager.shared.font(withFamily: "JetBrainsMono Nerd Font", traits: [], weight: w, size: size) {
        return Font(f)
    }
    return .system(size: size, weight: weight == .semibold ? .semibold : .regular, design: .monospaced)
}

private let memFormatter: ByteCountFormatter = {
    let f = ByteCountFormatter()
    f.countStyle = .memory
    f.allowedUnits = [.useMB, .useGB]
    return f
}()

private func formatMem(_ b: UInt64) -> String { memFormatter.string(fromByteCount: Int64(b)) }
private func formatCPU(_ c: Double) -> String { c < 0.05 ? "0" : String(format: c >= 10 ? "%.0f" : "%.1f", c) }

/// The sampler measures CPU like Activity Monitor: percent of ONE core, so a
/// busy app reads 250 on a 10-core Mac. The CPU column shows share of the
/// WHOLE Mac instead -- the same scale as the bar's CPU pill -- so 25% means a
/// quarter of the machine and the rows add up to roughly the bar's number.
private let cores = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))
private func machineShare(_ perCore: Double) -> Double { perCore / cores }
private func formatShare(_ s: Double) -> String {
    s < 0.05 ? "0%" : String(format: s >= 10 ? "%.0f%%" : "%.1f%%", s)
}
/// One full core's worth. A single app holding this much is either doing heavy
/// work or stuck in a loop -- the same point the old "90 of one core" red meant.
private let cpuHot = 100 / cores

enum Tab { case apps, processes }

struct RootView: View {
    @ObservedObject var store: Store
    let dismiss: () -> Void

    @State private var tab: Tab = .apps
    @State private var query = ""
    @State private var sort: SortKey = .memory
    @State private var allUsers = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(faint).frame(height: 1)
            columns
            ScrollView {
                LazyVStack(spacing: 1) {
                    if tab == .apps { appRows } else { procRows }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
            }
            Rectangle().fill(faint).frame(height: 1)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundColor(fg)
        .onAppear { searchFocused = true }
        .onChange(of: store.openCount) { _ in
            query = ""
            searchFocused = true
        }
    }

    // MARK: header

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(dim).font(.system(size: 11))
                TextField("Filter", text: $query)
                    .textFieldStyle(.plain)
                    .font(mono(11))
                    .focused($searchFocused)
                    .onSubmit(openFirstMatch)
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 7).fill(faint))

            HStack(spacing: 2) {
                tabButton("Apps", .apps, key: "1")
                tabButton("Processes", .processes, key: "2")
            }
            .frame(maxWidth: .infinity)
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 8).fill(faint))
        }
        .padding(8)
    }

    private func tabButton(_ title: String, _ t: Tab, key: KeyEquivalent) -> some View {
        Button { tab = t } label: {
            Text(title)
                .font(mono(11, tab == t ? .semibold : .regular))
                .foregroundColor(tab == t ? fg : dim)
                .frame(maxWidth: .infinity)
                .frame(height: 20)
                .background(RoundedRectangle(cornerRadius: 6).fill(tab == t ? Color.white.opacity(0.12) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key, modifiers: .command)
    }

    private var columns: some View {
        HStack(spacing: 0) {
            sortHeader("NAME", .name).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 26)
            sortHeader("CPU", .cpu).frame(width: cpuWidth, alignment: .trailing)
            sortHeader("GPU", .gpu).frame(width: gpuWidth, alignment: .trailing)
            sortHeader("MEM", .memory).frame(width: memWidth, alignment: .trailing)
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private func sortHeader(_ title: String, _ key: SortKey) -> some View {
        Button { sort = key } label: {
            Text(title)
                .font(mono(9.5, sort == key ? .semibold : .regular))
                .foregroundColor(sort == key ? fg : dim)
        }
        .buttonStyle(.plain)
    }

    // MARK: rows

    private func matches(_ name: String, _ pid: pid_t) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || name.localizedCaseInsensitiveContains(q) || String(pid).hasPrefix(q)
    }

    private func sorted<T>(_ items: [T], name: (T) -> String, cpu: (T) -> Double, gpu: (T) -> Double,
                           mem: (T) -> UInt64) -> [T] {
        items.sorted {
            switch sort {
            case .memory: return mem($0) > mem($1)
            case .cpu: return cpu($0) > cpu($1)
            case .gpu: return gpu($0) > gpu($1)
            case .name: return name($0).localizedCaseInsensitiveCompare(name($1)) == .orderedAscending
            }
        }
    }

    private var filteredApps: [AppEntry] {
        sorted(store.apps.filter { matches($0.name, $0.pid) }, name: \.name, cpu: \.cpu, gpu: \.gpu, mem: \.memory)
    }

    @ViewBuilder private var appRows: some View {
        let all = filteredApps
        let fore = all.filter { !$0.isBackground }
        let back = all.filter(\.isBackground)
        ForEach(fore) { AppRow(entry: $0, store: store, dismiss: dismiss) }
        if !back.isEmpty {
            sectionLabel("MENU BAR & BACKGROUND")
            ForEach(back) { AppRow(entry: $0, store: store, dismiss: dismiss) }
        }
        if all.isEmpty { emptyLabel }
    }

    private var filteredProcs: [Proc] {
        let uid = getuid()
        let list = store.procs.filter { (allUsers || $0.uid == uid) && matches($0.name, $0.pid) }
        return sorted(list, name: \.name, cpu: \.cpu, gpu: \.gpu, mem: \.memory)
    }

    @ViewBuilder private var procRows: some View {
        let list = filteredProcs
        ForEach(list) { ProcRow(proc: $0, store: store) }
        if list.isEmpty { emptyLabel }
    }

    private func sectionLabel(_ s: String) -> some View {
        Text(s)
            .font(mono(9.5, .semibold))
            .foregroundColor(dim)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 8)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    private var emptyLabel: some View {
        Text("Nothing matches \u{201C}\(query)\u{201D}")
            .font(mono(11))
            .foregroundColor(dim)
            .padding(.top, 40)
    }

    private func openFirstMatch() {
        guard tab == .apps, let first = filteredApps.first(where: { !$0.isBackground }) ?? filteredApps.first else { return }
        store.activate(first)
        dismiss()
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: 10) {
            if let s = store.status {
                Text(s).font(mono(9.5)).foregroundColor(fg).lineLimit(1).truncationMode(.middle)
            } else if tab == .apps {
                Text("\(store.apps.count) apps · \(formatMem(store.apps.reduce(0) { $0 + $1.memory })) · \(formatShare(machineShare(store.apps.reduce(0) { $0 + $1.cpu }))) CPU")
                    .font(mono(9.5)).foregroundColor(dim)
            } else {
                Text("\(filteredProcs.count) procs")
                    .font(mono(9.5)).foregroundColor(dim)
            }
            Spacer()
            if tab == .processes {
                Toggle(isOn: $allUsers) { Text("All users").font(mono(9.5)).foregroundColor(dim) }
                    .toggleStyle(.checkbox)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
    }
}

// MARK: - rows

private struct Stats: View {
    let cpu: Double
    let gpu: Double
    let memory: UInt64
    let hasStats: Bool

    var body: some View {
        let share = machineShare(cpu)
        Text(hasStats ? formatShare(share) : "--")
            .font(mono(10))
            .foregroundColor(share >= cpuHot ? critical : (share >= 0.1 ? fg : dim))
            .frame(width: cpuWidth, alignment: .trailing)
        Text(hasStats ? formatCPU(gpu) : "--")
            .font(mono(10))
            .foregroundColor(gpu >= 90 ? critical : (gpu >= 1 ? fg : dim))
            .frame(width: gpuWidth, alignment: .trailing)
        Text(hasStats ? formatMem(memory) : "--")
            .font(mono(10))
            .foregroundColor(hasStats ? fg : dim)
            .frame(width: memWidth, alignment: .trailing)
    }
}

/// The row's icon, which turns into its quit / kill button while hovered --
/// the panel is only as wide as the bar pill, so there is no spare column.
private struct IconOrKill<Icon: View>: View {
    let hover: Bool
    let force: Bool
    let disabled: Bool
    let help: String
    let action: () -> Void
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        ZStack {
            if hover && !disabled {
                Button(action: action) {
                    Image(systemName: force ? "xmark.octagon.fill" : "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(force ? critical : fg)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(help)
            } else {
                icon()
            }
        }
        .frame(width: 18, height: 18)
        .padding(.trailing, 8)
    }
}

private struct AppRow: View {
    let entry: AppEntry
    @ObservedObject var store: Store
    let dismiss: () -> Void
    @State private var hover = false

    private var subtitle: String {
        var parts: [String] = []
        if entry.instanceCount > 1 { parts.append("#\(entry.instance)/\(entry.instanceCount)") }
        if entry.windows > 0 { parts.append("\(entry.windows) win") }
        if entry.helpers > 0 { parts.append("+\(entry.helpers)") }
        parts.append("\(entry.pid)")
        if entry.app.isHidden { parts.append("hidden") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 0) {
            IconOrKill(hover: hover, force: store.optionDown, disabled: false,
                       help: store.optionDown ? "Force quit" : "Quit",
                       action: { store.quit(entry, force: store.optionDown) }) {
                Image(nsImage: entry.app.icon ?? NSImage(named: NSImage.applicationIconName)!)
                    .resizable()
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                Text(subtitle).font(mono(8.5)).foregroundColor(dim).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Stats(cpu: entry.cpu, gpu: entry.gpu, memory: entry.memory, hasStats: true)
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(hover ? Color.white.opacity(0.07) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture {
            store.activate(entry)
            dismiss()
        }
        .contextMenu {
            Button("Show") { store.activate(entry); dismiss() }
            Button(entry.app.isHidden ? "Unhide" : "Hide") {
                _ = entry.app.isHidden ? entry.app.unhide() : entry.app.hide()
            }
            if let url = entry.app.bundleURL {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            Button("Copy PID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(String(entry.pid), forType: .string)
            }
            Divider()
            Button("Quit") { store.quit(entry, force: false) }
            Button("Force Quit") { store.quit(entry, force: true) }
            if entry.instanceCount > 1 {
                Divider()
                Button("Quit All \(entry.instanceCount) Instances") { store.quitAllInstances(of: entry, force: false) }
                Button("Force Quit All \(entry.instanceCount) Instances") { store.quitAllInstances(of: entry, force: true) }
            }
        }
    }
}

/// Icons for bare executables: the enclosing .app when there is one (so
/// Helium's helpers show Helium), otherwise nil and a terminal glyph.
private var iconCache: [String: NSImage] = [:]
private func processIcon(_ path: String) -> NSImage? {
    guard let r = path.range(of: ".app/") else { return nil }
    let bundle = String(path[..<r.lowerBound]) + ".app"
    if let cached = iconCache[bundle] { return cached }
    let icon = NSWorkspace.shared.icon(forFile: bundle)
    iconCache[bundle] = icon
    return icon
}

private struct ProcRow: View {
    let proc: Proc
    @ObservedObject var store: Store
    @State private var hover = false

    var body: some View {
        let isProtected = protectedNames.contains(proc.name)
        HStack(spacing: 0) {
            IconOrKill(hover: hover, force: store.optionDown, disabled: isProtected,
                       help: store.optionDown ? "SIGKILL" : "SIGTERM",
                       action: { store.kill(proc, force: store.optionDown) }) {
                if let icon = processIcon(proc.path) {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "terminal").font(.system(size: 10)).foregroundColor(dim)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(proc.name).font(mono(10.5)).lineLimit(1)
                Text(proc.path.isEmpty ? "\(proc.pid)" : "\(proc.pid) · \(proc.path)")
                    .font(mono(8.5)).foregroundColor(dim).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Stats(cpu: proc.cpu, gpu: proc.gpu, memory: proc.memory, hasStats: proc.hasStats)
        }
        .help(isProtected ? "Killing \(proc.name) would end your session" : "")
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 7).fill(hover ? Color.white.opacity(0.07) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .contextMenu {
            Button("Copy PID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(String(proc.pid), forType: .string)
            }
            if !proc.path.isEmpty {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: proc.path)])
                }
            }
            Divider()
            Button("Terminate (SIGTERM)") { store.kill(proc, force: false) }.disabled(isProtected)
            Button("Kill (SIGKILL)") { store.kill(proc, force: true) }.disabled(isProtected)
        }
    }
}
