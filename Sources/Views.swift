import AppKit
import SwiftUI

// Palette mirrors sketchybar/colors.sh: monotone white at varying alpha,
// with red kept for the one thing worth shouting about.
private let fg = Color.white.opacity(0.95)
private let dim = Color.white.opacity(0.5)
private let faint = Color.white.opacity(0.08)
private let critical = Color(red: 1, green: 0.27, blue: 0.23)

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
private func formatCPU(_ c: Double) -> String { c < 0.05 ? "0.0" : String(format: c >= 100 ? "%.0f" : "%.1f", c) }

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
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            Rectangle().fill(faint).frame(height: 1)
            footer
        }
        .frame(width: 480, height: 580)
        .foregroundColor(fg)
        .onAppear { searchFocused = true }
        .onChange(of: store.openCount) { _ in
            query = ""
            searchFocused = true
        }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(dim).font(.system(size: 11))
                TextField("Filter by name or pid", text: $query)
                    .textFieldStyle(.plain)
                    .font(mono(12))
                    .focused($searchFocused)
                    .onSubmit(openFirstMatch)
            }
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(faint))

            HStack(spacing: 2) {
                tabButton("Apps", .apps, key: "1")
                tabButton("Processes", .processes, key: "2")
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 8).fill(faint))
        }
        .padding(10)
    }

    private func tabButton(_ title: String, _ t: Tab, key: KeyEquivalent) -> some View {
        Button { tab = t } label: {
            Text(title)
                .font(mono(11, tab == t ? .semibold : .regular))
                .foregroundColor(tab == t ? fg : dim)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(tab == t ? Color.white.opacity(0.12) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key, modifiers: .command)
    }

    private var columns: some View {
        HStack(spacing: 0) {
            sortHeader("NAME", .name).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 40)
            sortHeader("CPU %", .cpu).frame(width: 56, alignment: .trailing)
            sortHeader("MEMORY", .memory).frame(width: 76, alignment: .trailing)
            Color.clear.frame(width: 38, height: 1)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
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

    private func sorted<T>(_ items: [T], name: (T) -> String, cpu: (T) -> Double, mem: (T) -> UInt64) -> [T] {
        items.sorted {
            switch sort {
            case .memory: return mem($0) > mem($1)
            case .cpu: return cpu($0) > cpu($1)
            case .name: return name($0).localizedCaseInsensitiveCompare(name($1)) == .orderedAscending
            }
        }
    }

    private var filteredApps: [AppEntry] {
        sorted(store.apps.filter { matches($0.name, $0.pid) }, name: \.name, cpu: \.cpu, mem: \.memory)
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
        return sorted(list, name: \.name, cpu: \.cpu, mem: \.memory)
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
                Text(s).font(mono(10.5)).foregroundColor(fg).lineLimit(1)
            } else if tab == .apps {
                Text("\(store.apps.count) apps · \(formatMem(store.apps.reduce(0) { $0 + $1.memory })) · \u{2325} force quit")
                    .font(mono(10.5)).foregroundColor(dim)
            } else {
                Text("\(filteredProcs.count) processes · \u{2325} SIGKILL")
                    .font(mono(10.5)).foregroundColor(dim)
            }
            Spacer()
            if tab == .processes {
                Toggle(isOn: $allUsers) { Text("All users").font(mono(10.5)).foregroundColor(dim) }
                    .toggleStyle(.checkbox)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
    }
}

// MARK: - rows

private struct Stats: View {
    let cpu: Double
    let memory: UInt64
    let hasStats: Bool

    var body: some View {
        Text(hasStats ? formatCPU(cpu) : "--")
            .font(mono(11.5))
            .foregroundColor(cpu >= 90 ? critical : (cpu >= 1 ? fg : dim))
            .frame(width: 56, alignment: .trailing)
        Text(hasStats ? formatMem(memory) : "--")
            .font(mono(11.5))
            .foregroundColor(hasStats ? fg : dim)
            .frame(width: 76, alignment: .trailing)
    }
}

private struct KillButton: View {
    let force: Bool
    let visible: Bool
    let disabled: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: force ? "xmark.octagon.fill" : "xmark.circle.fill")
                .font(.system(size: 14))
                .foregroundColor(disabled ? dim.opacity(0.4) : (force ? critical : dim))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
        .opacity(visible ? 1 : 0)
        .frame(width: 38, alignment: .trailing)
    }
}

private struct AppRow: View {
    let entry: AppEntry
    @ObservedObject var store: Store
    let dismiss: () -> Void
    @State private var hover = false

    private var subtitle: String {
        var parts: [String] = ["pid \(entry.pid)"]
        if entry.instanceCount > 1 { parts.append("instance \(entry.instance)/\(entry.instanceCount)") }
        if entry.windows > 0 { parts.append("\(entry.windows) window\(entry.windows == 1 ? "" : "s")") }
        if entry.helpers > 0 { parts.append("\(entry.helpers) helper\(entry.helpers == 1 ? "" : "s")") }
        if entry.app.isHidden { parts.append("hidden") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 0) {
            Image(nsImage: entry.app.icon ?? NSImage(named: NSImage.applicationIconName)!)
                .resizable()
                .frame(width: 22, height: 22)
                .padding(.trailing, 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Text(subtitle).font(mono(9.5)).foregroundColor(dim).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Stats(cpu: entry.cpu, memory: entry.memory, hasStats: true)
            KillButton(force: store.optionDown, visible: hover, disabled: false,
                       help: store.optionDown ? "Force quit" : "Quit") {
                store.quit(entry, force: store.optionDown)
            }
        }
        .padding(.leading, 8)
        .padding(.vertical, 5)
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
            Group {
                if let icon = processIcon(proc.path) {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "terminal").font(.system(size: 11)).foregroundColor(dim)
                }
            }
            .frame(width: 18, height: 18)
            .padding(.leading, 2)
            .padding(.trailing, 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(proc.name).font(mono(11.5)).lineLimit(1)
                Text(proc.path.isEmpty ? "pid \(proc.pid)" : "pid \(proc.pid) · \(proc.path)")
                    .font(mono(9)).foregroundColor(dim).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Stats(cpu: proc.cpu, memory: proc.memory, hasStats: proc.hasStats)
            KillButton(force: store.optionDown, visible: hover, disabled: isProtected,
                       help: isProtected ? "Killing \(proc.name) would end your session"
                                         : (store.optionDown ? "SIGKILL" : "SIGTERM")) {
                store.kill(proc, force: store.optionDown)
            }
        }
        .padding(.leading, 8)
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
