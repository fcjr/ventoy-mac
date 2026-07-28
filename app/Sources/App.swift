import SwiftUI

@main
struct VentoyApp: App {
    var body: some Scene {
        WindowGroup("Ventoy2Disk") {
            ContentView()
        }
        .defaultSize(width: 560, height: 620)
    }
}

struct ContentView: View {
    @StateObject private var runner = Runner()
    @State private var disks: [DiskInfo] = []
    @State private var selectedID: String?
    @State private var useGPT = false
    @State private var secureBoot = true
    @State private var label = "Ventoy"
    @State private var reserveMB = ""
    @State private var latest: String?
    @State private var confirmErase = false
    @State private var confirmErase2 = false
    @State private var consoleOpen = false

    private var selected: DiskInfo? { disks.first { $0.id == selectedID } }
    private var phase: InstallPhase {
        InstallPhase.parse(runner.log, running: runner.running)
    }
    private var reserveBytes: UInt64 {
        UInt64(max(0, Int(reserveMB.trimmingCharacters(in: .whitespaces)) ?? 0)) * 1_048_576
    }

    var body: some View {
        VStack(spacing: 0) {
            form
            Divider()
            bottomBar
        }
        .frame(minWidth: 540, minHeight: 500)
        .onAppear {
            refresh()
            Task { latest = await DiskLister.latestReleaseTag() }
        }
        .onChange(of: runner.running) { running in
            if running { consoleOpen = true } else { refresh() }
        }
        .alert("Erase \(selected?.id ?? "disk")?", isPresented: $confirmErase) {
            Button("Cancel", role: .cancel) {}
            Button("Continue", role: .destructive) { confirmErase2 = true }
        } message: {
            Text("All data on \(selected?.mediaName ?? "") (\(selected?.sizeString ?? "")) will be permanently lost.")
        }
        .alert("Are you absolutely sure?", isPresented: $confirmErase2) {
            Button("Cancel", role: .cancel) {}
            Button("Erase and Install", role: .destructive) { runInstall() }
        } message: {
            Text("\(selected?.devPath ?? "") will be wiped and Ventoy will be installed (\(useGPT ? "GPT" : "MBR")).")
        }
    }

    private var form: some View {
        Form {
            Section("Device") {
                HStack {
                    Picker("Disk", selection: $selectedID) {
                        if disks.isEmpty {
                            Text("No external disks").tag(String?.none)
                        }
                        ForEach(disks) { d in
                            Text("\(d.mediaName) (\(d.sizeString)) — \(d.id)").tag(Optional(d.id))
                        }
                    }
                    .disabled(runner.running)
                    .help("The external disk to install Ventoy on")
                    Button {
                        refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(runner.running)
                    .help("Rescan external disks")
                }
                if let d = selected {
                    LabeledContent("Ventoy") {
                        Text(d.ventoyInstalled
                             ? "\(d.ventoyVersion ?? "Installed") (\(d.scheme ?? "?"))"
                             : "Not installed")
                            .foregroundStyle(d.ventoyInstalled ? .primary : .secondary)
                    }
                    .help(d.ventoyInstalled
                          ? "This disk already has the Ventoy layout. Update keeps the files on the data partition."
                          : "No Ventoy layout detected on this disk.")
                    LabeledContent("Now") {
                        PartitionBar(regions: nowRegions(d), faded: true)
                            .frame(maxWidth: .infinity)
                            .help("Current layout — everything here is erased by an install.")
                    }
                    LabeledContent("After") {
                        PartitionBar(regions: afterRegions(d),
                                     activeID: runner.running ? phase.activeRegion : nil)
                            .frame(maxWidth: .infinity)
                            .help("Layout written by the installer. Small regions are drawn wider than scale.")
                    }
                    HStack(spacing: 12) {
                        ForEach(legend(d), id: \.text) { item in
                            LegendItem(kind: item.kind, text: item.text)
                        }
                        Spacer()
                        Text("\(d.sectorCount.formatted()) sectors")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Insert a USB drive, then rescan.")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Latest release", value: latest ?? "…")
                    .help("Latest Ventoy release on GitHub. Installs download this version automatically.")
            }

            Section("Options") {
                Picker("Partition style", selection: $useGPT) {
                    Text("MBR").tag(false)
                    Text("GPT").tag(true)
                }
                .pickerStyle(.segmented)
                .help("MBR boots the widest range of machines; GPT is required for disks over 2 TB.")
                Toggle("Secure boot support", isOn: $secureBoot)
                    .help("Keep the shim chain so the drive boots with Secure Boot enabled. Turn off only if a machine rejects the shim.")
                TextField("Volume label", text: $label)
                    .help("Volume label for the exFAT data partition")
                TextField("Reserved space (MB)", text: $reserveMB)
                    .help("Leave unpartitioned space at the end of the disk, before the VTOYEFI partition")
            }
            .disabled(runner.running)

            Section {
                DisclosureGroup("Console", isExpanded: $consoleOpen) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            Text(runner.log.isEmpty ? "Idle." : runner.log)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id("logEnd")
                        }
                        .frame(height: 160)
                        .onChange(of: runner.log) { _ in
                            proxy.scrollTo("logEnd", anchor: .bottom)
                        }
                    }
                }
                .help("Raw output from the ventoy2disk installer")
            }
        }
        .formStyle(.grouped)
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            status
            Spacer()
            Button("Update Ventoy") {
                runUpdate()
            }
            .disabled(runner.running || selected?.ventoyInstalled != true)
            .help("Updates the boot files in place. Files on the data partition are untouched.")
            Button(selected?.ventoyInstalled == true ? "Reinstall Ventoy…" : "Install Ventoy…") {
                confirmErase = true
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(runner.running || selected == nil)
            .help("Erases the whole disk and installs Ventoy. Asks twice before touching anything.")
        }
        .padding(12)
    }

    @ViewBuilder
    private var status: some View {
        if runner.running {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(phase.label ?? "Waiting for authorization…")
                    .foregroundStyle(.secondary)
            }
        } else if runner.canceled {
            Text("Canceled.")
                .foregroundStyle(.secondary)
        } else if runner.lastSucceeded == true {
            Label("Done — copy ISO files to '\(label.trimmingCharacters(in: .whitespaces).isEmpty ? "Ventoy" : label)'",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else if runner.lastSucceeded == false {
            Label("Failed — see console", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private struct LegendSpec {
        let kind: RegionKind
        let text: String
    }

    private func legend(_ d: DiskInfo) -> [LegendSpec] {
        var items = [
            LegendSpec(kind: .boot, text: "grub"),
            LegendSpec(kind: .data, text: "exFAT \(dataSizeString(d))"),
        ]
        if reserveBytes > 0 {
            items.append(LegendSpec(kind: .reserved,
                                    text: "reserved \(reserveMB.trimmingCharacters(in: .whitespaces)) MB"))
        }
        items.append(LegendSpec(kind: .efi, text: "VTOYEFI 32 MB"))
        return items
    }

    private func dataSizeString(_ d: DiskInfo) -> String {
        let overhead = UInt64(33_554_432) + 1_048_576 + reserveBytes
        let bytes = d.size > overhead ? d.size - overhead : 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func nowRegions(_ d: DiskInfo) -> [MapRegion] {
        if d.parts.isEmpty {
            return [MapRegion(id: "raw", label: "no partitions", kind: .existing, size: d.size)]
        }
        return d.parts.map { p in
            MapRegion(id: p.id,
                      label: p.name ?? p.content ?? "partition",
                      kind: .existing,
                      size: p.size)
        }
    }

    private func afterRegions(_ d: DiskInfo) -> [MapRegion] {
        var regions = [
            MapRegion(id: "boot", label: "grub", kind: .boot, size: 1_048_576, fixedWidth: 8),
            MapRegion(id: "data", label: "exFAT", kind: .data, size: max(d.size, 1)),
        ]
        if reserveBytes > 0 {
            regions.append(MapRegion(id: "rsv", label: "reserved", kind: .reserved,
                                     size: reserveBytes, fixedWidth: 20))
        }
        regions.append(MapRegion(id: "efi", label: "VTOYEFI", kind: .efi,
                                 size: 33_554_432, fixedWidth: 36))
        return regions
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

    private func runInstall() {
        guard let d = selected else { return }
        var args = [d.ventoyInstalled ? "-I" : "-i", "-y"]
        if useGPT { args.append("-g") }
        if !secureBoot { args.append("-S") }
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            args += ["-L", trimmed]
        }
        if let mb = Int(reserveMB.trimmingCharacters(in: .whitespaces)), mb > 0 {
            args += ["-r", String(mb)]
        }
        args.append(d.devPath)
        runner.run(arguments: args)
    }

    private func runUpdate() {
        guard let d = selected else { return }
        runner.run(arguments: ["-u", "-y", d.devPath])
    }
}
