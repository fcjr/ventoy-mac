import SwiftUI

@main
struct VentoyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
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

    private var selected: DiskInfo? { disks.first { $0.id == selectedID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            deviceSection
            Divider()
            optionsSection
            buttons
            logView
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 520)
        .onAppear {
            refresh()
            Task { latest = await DiskLister.latestReleaseTag() }
        }
        .onChange(of: runner.running) { r in
            if !r { refresh() }
        }
    }

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Device", selection: $selectedID) {
                    if disks.isEmpty {
                        Text("No external disks found").tag(String?.none)
                    }
                    ForEach(disks) { d in
                        Text("\(d.id) — \(d.mediaName) (\(d.sizeString))").tag(Optional(d.id))
                    }
                }
                .disabled(runner.running)
                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(runner.running)
                .help("Rescan disks")
            }
            HStack {
                if let d = selected {
                    if d.ventoyInstalled {
                        Label("Ventoy \(d.ventoyVersion ?? "installed") (\(d.scheme ?? "?"))",
                              systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Ventoy not installed", systemImage: "circle")
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text("Latest release: \(latest ?? "…")")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Partition style", selection: $useGPT) {
                    Text("MBR").tag(false)
                    Text("GPT").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
                Spacer()
                Toggle("Secure boot support", isOn: $secureBoot)
            }
            HStack {
                Text("Label")
                TextField("Ventoy", text: $label)
                    .frame(maxWidth: 140)
                Text("Reserve at end (MB)")
                    .padding(.leading, 12)
                TextField("0", text: $reserveMB)
                    .frame(maxWidth: 80)
                Spacer()
            }
        }
        .disabled(runner.running)
    }

    private var buttons: some View {
        HStack {
            Button(selected?.ventoyInstalled == true ? "Reinstall" : "Install") {
                confirmErase = true
            }
            .disabled(runner.running || selected == nil)
            Button("Update") {
                runUpdate()
            }
            .disabled(runner.running || selected?.ventoyInstalled != true)
            if runner.running {
                ProgressView()
                    .controlSize(.small)
                    .padding(.leading, 8)
            }
            Spacer()
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

    private var logView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Log")
                .font(.callout)
                .foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView {
                    Text(runner.log.isEmpty ? " " : runner.log)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .id("logEnd")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3)))
                .onChange(of: runner.log) { _ in
                    proxy.scrollTo("logEnd", anchor: .bottom)
                }
            }
        }
        .frame(maxHeight: .infinity)
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
