import SwiftUI

struct InstallOptions {
    var gpt = false
    var secureBoot = true
    var label = "Ventoy"
    var reserveMB = ""

    var reserveBytes: UInt64 {
        UInt64(max(0, Int(reserveMB.trimmingCharacters(in: .whitespaces)) ?? 0)) * 1_048_576
    }
}

struct InstallSheet: View {
    let disk: DiskInfo
    let onConfirm: (InstallOptions) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var options = InstallOptions()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "externaldrive.badge.plus")
                    .font(.system(size: 34))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Install Ventoy on “\(disk.mediaName)”?")
                        .font(.headline)
                    Text("Installing erases all data on \(disk.devPath) (\(disk.sizeString)). This can’t be undone.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Form {
                Picker("Partition style:", selection: $options.gpt) {
                    Text("Master Boot Record").tag(false)
                    Text("GUID Partition Map").tag(true)
                }
                .help("Master Boot Record boots the widest range of machines; GUID Partition Map is required for disks over 2 TB.")
                Toggle("Secure boot support", isOn: $options.secureBoot)
                    .help("Keep the shim chain so the drive boots with Secure Boot enabled. Turn off only if a machine rejects the shim.")
                TextField("Volume label:", text: $options.label)
                    .help("Volume label for the exFAT data partition")
                TextField("Reserved space (MB):", text: $options.reserveMB, prompt: Text("0"))
                    .help("Leave unpartitioned space at the end of the disk, before the VTOYEFI partition")
            }
            .formStyle(.columns)

            VStack(alignment: .leading, spacing: 6) {
                Text("After installing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                PartitionBar(regions: afterRegions(disk, options))
                    .help("Layout written by the installer. Small regions are drawn wider than scale.")
                HStack(spacing: 12) {
                    ForEach(afterLegend(disk, options), id: \.text) { item in
                        LegendItem(kind: item.kind, text: item.text)
                    }
                    Spacer()
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Erase and Install") {
                    dismiss()
                    onConfirm(options)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

struct ProgressSheet: View {
    @ObservedObject var runner: Runner
    let disk: DiskInfo?
    let actionTitle: String
    let onDone: () -> Void
    @State private var detailsOpen = false

    private var phase: InstallPhase {
        InstallPhase.parse(runner.log, running: runner.running)
    }

    private var title: String {
        if runner.running { return "\(actionTitle) “\(disk?.mediaName ?? "disk")”…" }
        if runner.canceled { return "\(actionTitle) canceled" }
        if runner.lastSucceeded == true { return "\(actionTitle) complete" }
        return "\(actionTitle) failed"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                statusIcon
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }

            if runner.running {
                ProgressView()
                    .progressViewStyle(.linear)
            }

            if let d = disk, runner.running {
                PartitionBar(regions: afterRegions(d, InstallOptions()),
                             activeID: phase.activeRegion)
            }

            Button {
                withAnimation(.easeOut(duration: 0.2)) { detailsOpen.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(detailsOpen ? 90 : 0))
                    Text(detailsOpen ? "Hide Details" : "Show Details")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Raw output from the ventoy2disk installer")

            ScrollViewReader { proxy in
                ScrollView {
                    Text(runner.log.isEmpty ? " " : runner.log)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .id("logEnd")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1))
                .onChange(of: runner.log) { _ in
                    proxy.scrollTo("logEnd", anchor: .bottom)
                }
            }
            .frame(height: detailsOpen ? 150 : 0)
            .clipped()
            .opacity(detailsOpen ? 1 : 0)
            .accessibilityHidden(!detailsOpen)

            HStack {
                Spacer()
                Button("Done") { onDone() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(runner.running)
            }
        }
        .padding(20)
        .frame(width: 460)
        .interactiveDismissDisabled(runner.running)
        .onChange(of: runner.lastSucceeded) { ok in
            if ok == false {
                withAnimation(.easeOut(duration: 0.2)) { detailsOpen = true }
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if runner.running {
            ProgressView()
                .controlSize(.regular)
                .frame(width: 34)
        } else if runner.lastSucceeded == true {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.green)
                .frame(width: 34)
        } else if runner.canceled {
            Image(systemName: "minus.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
                .frame(width: 34)
        } else {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.yellow)
                .frame(width: 34)
        }
    }

    private var subtitle: String {
        if runner.running {
            return phase.label ?? "Waiting for authorization…"
        }
        if runner.canceled {
            return "No changes were made to the disk."
        }
        if runner.lastSucceeded == true {
            return "You can copy ISO files to the drive once macOS remounts it."
        }
        return "The installer reported an error. See details below."
    }
}

func afterRegions(_ d: DiskInfo, _ options: InstallOptions) -> [MapRegion] {
    var regions = [
        MapRegion(id: "boot", label: "grub", kind: .boot, size: 1_048_576, fixedWidth: 8),
        MapRegion(id: "data", label: "exFAT", kind: .data, size: max(d.size, 1)),
    ]
    if options.reserveBytes > 0 {
        regions.append(MapRegion(id: "rsv", label: "reserved", kind: .reserved,
                                 size: options.reserveBytes, fixedWidth: 20))
    }
    regions.append(MapRegion(id: "efi", label: "VTOYEFI", kind: .efi,
                             size: 33_554_432, fixedWidth: 36))
    return regions
}

struct LegendSpec {
    let kind: RegionKind
    let text: String
}

func afterLegend(_ d: DiskInfo, _ options: InstallOptions) -> [LegendSpec] {
    let overhead = UInt64(33_554_432) + 1_048_576 + options.reserveBytes
    let dataBytes = d.size > overhead ? d.size - overhead : 0
    let dataSize = ByteCountFormatter.string(fromByteCount: Int64(dataBytes), countStyle: .file)
    var items = [
        LegendSpec(kind: .boot, text: "grub"),
        LegendSpec(kind: .data, text: "exFAT \(dataSize)"),
    ]
    if options.reserveBytes > 0 {
        items.append(LegendSpec(kind: .reserved,
                                text: "reserved \(options.reserveMB.trimmingCharacters(in: .whitespaces)) MB"))
    }
    items.append(LegendSpec(kind: .efi, text: "VTOYEFI 32 MB"))
    return items
}
