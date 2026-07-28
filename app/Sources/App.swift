import SwiftUI

@main
struct VentoyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 680, height: 560)
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
        VStack(alignment: .leading, spacing: 14) {
            header
            devicePanel
            optionsRow
            actionRow
            console
        }
        .padding(20)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minWidth: 620, minHeight: 560)
        .background(Theme.bezel.ignoresSafeArea())
        .tint(Theme.phosphor)
        .preferredColorScheme(.dark)
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
            Button("Erase and install", role: .destructive) { runInstall() }
        } message: {
            Text("\(selected?.devPath ?? "") will be wiped and Ventoy will be installed (\(useGPT ? "GPT" : "MBR")).")
        }
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.phosphor)
                    .frame(width: 8, height: 14)
                Text("VENTOY2DISK")
                    .font(Theme.mono(12, .semibold))
                    .tracking(2.5)
                    .foregroundStyle(Theme.ink)
            }
            Spacer()
            Text(latest.map { "latest release \($0)" } ?? "checking latest release…")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.dim)
                .help("Latest Ventoy release on GitHub. Installs download this version automatically.")
        }
        .padding(.leading, 58)
        .padding(.top, 2)
    }

    // MARK: device + layout

    private var devicePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Eyebrow(text: "DEVICE")
                Spacer()
                Picker("", selection: $selectedID) {
                    if disks.isEmpty {
                        Text("No external disks").tag(String?.none)
                    }
                    ForEach(disks) { d in
                        Text("\(d.id) — \(d.mediaName)").tag(Optional(d.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 240)
                .disabled(runner.running)
                .help("Choose the external disk to install Ventoy on")
                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.dim)
                .disabled(runner.running)
                .help("Rescan external disks")
            }

            if let d = selected {
                VStack(alignment: .leading, spacing: 3) {
                    Text(d.mediaName)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    HStack(spacing: 0) {
                        Text("\(d.devPath) · \(d.sizeString) · \(d.scheme ?? "no partition table")")
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.dim)
                        if d.ventoyInstalled {
                            Text(" · Ventoy \(d.ventoyVersion ?? "installed")")
                                .font(Theme.mono(12))
                                .foregroundStyle(Theme.phosphor)
                                .help("This disk already has the Ventoy layout. Update keeps the files on the data partition.")
                        }
                    }
                }
                layoutMap(d)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No external disks")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    Text("Insert a USB drive, then rescan.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.dim)
                }
                .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline, lineWidth: 1))
    }

    private func layoutMap(_ d: DiskInfo) -> some View {
        let after = afterRegions(d)
        return VStack(alignment: .leading, spacing: 6) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Eyebrow(text: "NOW")
                    PartitionBar(regions: nowRegions(d), faded: true)
                        .help(d.ventoyInstalled
                              ? "Current layout: this disk already carries Ventoy."
                              : "Current layout — everything here is erased by an install.")
                }
                GridRow {
                    Eyebrow(text: "AFTER")
                    PartitionBar(regions: after, activeID: runner.running ? phase.activeRegion : nil)
                        .help("Layout written by the installer. Small regions are drawn wider than scale.")
                }
            }
            HStack(spacing: 14) {
                Text("sector 0")
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.dim)
                Spacer()
                ForEach(legend(d)) { item in
                    LegendItem(item.color, hatched: item.hatched, item.text)
                }
                Spacer()
                Text("\(d.sectorCount.formatted()) sectors")
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.dim)
            }
            .padding(.leading, 44)
        }
        .padding(.top, 4)
    }

    private struct LegendSpec: Identifiable {
        let id: String
        let color: Color
        let hatched: Bool
        let text: String
    }

    private func legend(_ d: DiskInfo) -> [LegendSpec] {
        var items = [
            LegendSpec(id: "boot", color: Theme.phosphor.opacity(0.45), hatched: false, text: "grub"),
            LegendSpec(id: "data", color: Theme.steel, hatched: false,
                       text: "exFAT \(dataSizeString(d))"),
        ]
        if reserveBytes > 0 {
            items.append(LegendSpec(id: "rsv", color: Theme.well, hatched: true,
                                    text: "reserved \(reserveMB.trimmingCharacters(in: .whitespaces)) MB"))
        }
        items.append(LegendSpec(id: "efi", color: Theme.phosphor, hatched: false, text: "VTOYEFI 32 MB"))
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
            MapRegion(id: "boot", label: "grub", kind: .boot, size: 1_048_576, fixedWidth: 10),
            MapRegion(id: "data", label: "exFAT", kind: .data, size: max(d.size, 1)),
        ]
        if reserveBytes > 0 {
            regions.append(MapRegion(id: "rsv", label: "reserved", kind: .reserved,
                                     size: reserveBytes, fixedWidth: 24))
        }
        regions.append(MapRegion(id: "efi", label: "VTOYEFI", kind: .efi,
                                 size: 33_554_432, fixedWidth: 44))
        return regions
    }

    // MARK: options

    private var optionsRow: some View {
        HStack(spacing: 18) {
            Picker("", selection: $useGPT) {
                Text("MBR").tag(false)
                Text("GPT").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 130)
            .help("Partition table style. MBR boots the widest range of machines; GPT is required for disks over 2 TB.")

            Toggle("Secure boot", isOn: $secureBoot)
                .toggleStyle(.checkbox)
                .foregroundStyle(Theme.ink)
                .help("Keep the shim chain so the drive boots with Secure Boot enabled. Turn off only if a machine rejects the shim.")

            HStack(spacing: 6) {
                Text("Label")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
                TextField("Ventoy", text: $label)
                    .modifier(FieldStyle())
                    .frame(width: 110)
                    .help("Volume label for the exFAT data partition")
            }

            HStack(spacing: 6) {
                Text("Reserve")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
                TextField("0", text: $reserveMB)
                    .modifier(FieldStyle())
                    .frame(width: 64)
                Text("MB")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
            }
            .help("Leave unpartitioned space at the end of the disk, before the VTOYEFI partition")

            Spacer()
        }
        .disabled(runner.running)
    }

    // MARK: actions

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button(selected?.ventoyInstalled == true ? "Erase and reinstall Ventoy" : "Erase and install Ventoy") {
                confirmErase = true
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(runner.running || selected == nil)
            .help("Erases the whole disk and installs Ventoy. Asks twice before touching anything.")

            Button("Update Ventoy") {
                runUpdate()
            }
            .buttonStyle(QuietButtonStyle())
            .disabled(runner.running || selected?.ventoyInstalled != true)
            .help("Updates the boot files in place. Files on the data partition are untouched.")

            statusText
            Spacer()
        }
    }

    @ViewBuilder
    private var statusText: some View {
        if runner.running {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(phase.label ?? "Waiting for authorization…")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.phosphor)
            }
            .padding(.leading, 6)
        } else if runner.lastSucceeded == true {
            Text("Done — copy ISO files to the '\(label.isEmpty ? "Ventoy" : label)' volume.")
                .font(Theme.mono(12))
                .foregroundStyle(Theme.ok)
                .padding(.leading, 6)
        } else if runner.lastSucceeded == false {
            Text(phase == .failed ? "Failed — see console." : "Canceled.")
                .font(Theme.mono(12))
                .foregroundStyle(phase == .failed ? Theme.danger : Theme.dim)
                .padding(.leading, 6)
        }
    }

    // MARK: console

    private var console: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { consoleOpen.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(consoleOpen ? 90 : 0))
                    Eyebrow(text: "CONSOLE")
                }
                .foregroundStyle(Theme.dim)
            }
            .buttonStyle(.plain)
            .help("Raw output from the ventoy2disk installer")

            if consoleOpen {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(runner.log.isEmpty ? "Idle." : runner.log)
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.phosphor.opacity(0.85))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .id("logEnd")
                    }
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.well))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline, lineWidth: 1))
                    .onChange(of: runner.log) { _ in
                        proxy.scrollTo("logEnd", anchor: .bottom)
                    }
                }
                .frame(minHeight: 110, maxHeight: .infinity)
            }
        }
        .frame(maxHeight: consoleOpen ? .infinity : nil, alignment: .top)
    }

    // MARK: actions

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
