import SwiftUI

@main
struct VentoyApp: App {
    var body: some Scene {
        WindowGroup("Ventoy2Disk") {
            ContentView()
        }
        .defaultSize(width: 760, height: 480)
        .commands {
            CommandGroup(after: .toolbar) {
                RescanCommand()
            }
        }
    }
}

struct RescanCommand: View {
    @FocusedValue(\.refreshDisks) private var refresh
    var body: some View {
        Button("Rescan Disks") { refresh?() }
            .keyboardShortcut("r")
            .disabled(refresh == nil)
    }
}

struct RefreshDisksKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var refreshDisks: (() -> Void)? {
        get { self[RefreshDisksKey.self] }
        set { self[RefreshDisksKey.self] = newValue }
    }
}

struct ContentView: View {
    @StateObject private var runner = Runner()
    @State private var disks: [DiskInfo] = []
    @State private var selectedID: String?
    @State private var latest: String?
    @State private var showInstallSheet = false
    @State private var showProgress = false
    @State private var actionTitle = "Install"

    private var selected: DiskInfo? { disks.first { $0.id == selectedID } }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar
        } detail: {
            if let d = selected {
                DiskDetailView(disk: d, latest: latest)
            } else {
                emptyState
            }
        }
        .navigationTitle(selected?.mediaName ?? "Ventoy2Disk")
        .navigationSubtitle(selected.map { subtitle(for: $0) } ?? "")
        .toolbar { toolbarContent }
        .focusedSceneValue(\.refreshDisks, refresh)
        .frame(minWidth: 700, minHeight: 420)
        .onAppear {
            refresh()
            Task { latest = await DiskLister.latestReleaseTag() }
        }
        .onChange(of: runner.running) { _, running in
            if !running { refresh() }
        }
        .sheet(isPresented: $showInstallSheet) {
            if let d = selected {
                InstallSheet(disk: d) { options in
                    actionTitle = d.ventoyInstalled ? "Reinstall" : "Install"
                    runInstall(d, options)
                    showProgress = true
                }
            }
        }
        .sheet(isPresented: $showProgress) {
            ProgressSheet(runner: runner, disk: selected, actionTitle: actionTitle) {
                showProgress = false
            }
        }
    }

    private var sidebar: some View {
        List(selection: $selectedID) {
            Section("External") {
                if disks.isEmpty {
                    Text("No disks")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(disks) { d in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(d.mediaName)
                                    .lineLimit(1)
                                Text(d.sizeString)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "externaldrive")
                        }
                        .tag(d.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 170, ideal: 200)
        .toolbar(removing: .sidebarToggle)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                refresh()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(runner.running)
            .help("Rescan external disks (⌘R)")

            Button {
                guard let d = selected else { return }
                actionTitle = "Update"
                runUpdate(d)
                showProgress = true
            } label: {
                Label("Update", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(runner.running || selected?.ventoyInstalled != true)
            .help("Update the boot files in place. Files on the data partition are untouched.")

            Button {
                showInstallSheet = true
            } label: {
                Label("Install Ventoy…", systemImage: "externaldrive.badge.plus")
            }
            .disabled(runner.running || selected == nil)
            .help("Erase the selected disk and install Ventoy")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.system(size: 44))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            Text("No External Disks")
                .font(.title3.weight(.medium))
            Text("Insert a USB drive, then rescan.")
                .foregroundStyle(.secondary)
            Button("Rescan") { refresh() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func subtitle(for d: DiskInfo) -> String {
        var parts = [d.sizeString, schemeName(d.scheme)]
        if d.ventoyInstalled {
            parts.append("Ventoy \(d.ventoyVersion ?? "installed")")
        }
        return parts.joined(separator: " · ")
    }

    private func refresh() {
        Task {
            let list = await Task.detached { DiskLister.externalDisks() }.value
            disks = list
            if selectedID == nil || !list.contains(where: { $0.id == selectedID }) {
                selectedID = list.first?.id
            }
        }
    }

    private func runInstall(_ d: DiskInfo, _ options: InstallOptions) {
        var args = [d.ventoyInstalled ? "-I" : "-i", "-y"]
        if options.gpt { args.append("-g") }
        if !options.secureBoot { args.append("-S") }
        let trimmed = options.label.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            args += ["-L", trimmed]
        }
        if let mb = Int(options.reserveMB.trimmingCharacters(in: .whitespaces)), mb > 0 {
            args += ["-r", String(mb)]
        }
        args.append(d.devPath)
        runner.run(arguments: args)
    }

    private func runUpdate(_ d: DiskInfo) {
        runner.run(arguments: ["-u", "-y", d.devPath])
    }
}

func schemeName(_ scheme: String?) -> String {
    switch scheme {
    case "MBR": return "Master Boot Record"
    case "GPT": return "GUID Partition Map"
    default: return "No partition table"
    }
}

struct DiskDetailView: View {
    let disk: DiskInfo
    let latest: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "externaldrive")
                    .font(.system(size: 40))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(disk.mediaName)
                        .font(.title2.weight(.semibold))
                    Text("External · \(schemeName(disk.scheme))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                PartitionBar(regions: nowRegions)
                    .help(disk.ventoyInstalled
                          ? "Current layout: this disk carries Ventoy. Small regions are drawn wider than scale."
                          : "Current layout — installing Ventoy erases everything here.")
                HStack(spacing: 12) {
                    ForEach(nowLegend, id: \.text) { item in
                        LegendItem(kind: item.kind, text: item.text)
                    }
                    Spacer()
                    Text("\(disk.sectorCount.formatted()) sectors")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Grid(alignment: .topLeading, horizontalSpacing: 40, verticalSpacing: 16) {
                GridRow {
                    infoCell("Device node", disk.devPath, mono: true)
                    infoCell("Capacity", disk.sizeString)
                    infoCell("Partition map", schemeName(disk.scheme))
                }
                GridRow {
                    infoCell("Ventoy",
                             disk.ventoyInstalled
                             ? (disk.ventoyVersion ?? "Installed")
                             : "Not installed")
                    infoCell("Latest release", latest ?? "…")
                    Color.clear
                        .gridCellUnsizedAxes([.horizontal, .vertical])
                }
            }

            if !disk.ventoyInstalled {
                Text("Install Ventoy to boot ISO files from this drive.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func infoCell(_ title: String, _ value: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(mono ? .body.monospaced() : .body)
        }
    }

    private var nowRegions: [MapRegion] {
        if disk.parts.isEmpty {
            return [MapRegion(id: "raw", label: "No partitions", kind: .existing, size: disk.size)]
        }
        if disk.ventoyInstalled, disk.parts.count == 2 {
            let p1 = disk.parts[0]
            let p2 = disk.parts[1]
            return [
                MapRegion(id: p1.id, label: p1.name ?? "exFAT", kind: .data, size: p1.size),
                MapRegion(id: p2.id, label: "VTOYEFI", kind: .efi, size: p2.size, fixedWidth: 36),
            ]
        }
        return disk.parts.map { p in
            MapRegion(id: p.id,
                      label: p.name ?? p.content ?? "partition",
                      kind: .existing,
                      size: p.size)
        }
    }

    private var nowLegend: [LegendSpec] {
        if disk.ventoyInstalled, disk.parts.count == 2 {
            let dataSize = ByteCountFormatter.string(fromByteCount: Int64(disk.parts[0].size),
                                                     countStyle: .file)
            return [
                LegendSpec(kind: .data, text: "\(disk.parts[0].name ?? "exFAT") \(dataSize)"),
                LegendSpec(kind: .efi, text: "VTOYEFI 32 MB"),
            ]
        }
        return disk.parts.map { p in
            let size = ByteCountFormatter.string(fromByteCount: Int64(p.size), countStyle: .file)
            return LegendSpec(kind: .existing, text: "\(p.name ?? p.content ?? "partition") \(size)")
        }
    }
}
