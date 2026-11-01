import SwiftUI
import UniformTypeIdentifiers

struct BootMenuValues: Equatable {
    var menuMode = "0"
    var automatic = false
    var delay = 10
    var image = ""

    /// The timeout written to disk; nil removes the control.
    var timeout: String? { automatic ? String(delay) : nil }

    init() {}

    init(configuration: BootMenuConfiguration) throws {
        menuMode = configuration.value("VTOY_DEFAULT_MENU_MODE") ?? "0"
        if let text = configuration.value("VTOY_MENU_TIMEOUT") {
            guard let seconds = Int(text) else { throw ConfigurationError.invalidDocument }
            // grub treats a negative timeout as "wait for a selection".
            if seconds >= 0 {
                automatic = true
                delay = seconds
            }
        }
        image = configuration.value("VTOY_DEFAULT_IMAGE") ?? ""
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.menuMode == rhs.menuMode && lhs.timeout == rhs.timeout && lhs.image == rhs.image
    }
}

struct BootMenuSheet: View {
    let disk: DiskInfo
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: ConfigurationSnapshot?
    @State private var mount: DataVolume?
    @State private var values = BootMenuValues()
    @State private var initial = BootMenuValues()
    @State private var loading = true
    @State private var saving = false
    @State private var errorMessage: String?

    private var busy: Bool { loading || saving }
    private var changed: Bool { values != initial }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Boot Menu").font(.headline)
            Text(disk.parts.first?.name ?? disk.mediaName).foregroundStyle(.secondary)
            if let snapshot {
                Form {
                    Picker("Menu style", selection: $values.menuMode) {
                        Text("List").tag("0")
                        Text("Folders").tag("1")
                        if values.menuMode != "0" && values.menuMode != "1" {
                            Text("Current value (\(values.menuMode))").tag(values.menuMode)
                        }
                    }
                    Toggle("Boot automatically", isOn: $values.automatic)
                    if values.automatic {
                        Stepper("Delay: \(values.delay) seconds", value: $values.delay, in: 0...Int.max)
                    } else {
                        Text("Wait for an image to be selected.").foregroundStyle(.secondary)
                    }
                    LabeledContent("Default image") {
                        VStack(alignment: .trailing, spacing: 6) {
                            Text(values.image.isEmpty ? "First image" : values.image).lineLimit(2)
                                .textSelection(.enabled)
                            HStack {
                                if !values.image.isEmpty { Button("Use First Image") { values.image = "" } }
                                Button("Choose…", action: chooseImage)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .disabled(busy)
                if snapshot.configuration.hasModeOverrides {
                    Text("This drive also has firmware-specific settings, which can override these global settings.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    .disabled(saving)
                Button("Save Changes", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || snapshot == nil || !changed)
            }
        }
        .padding(20)
        .frame(width: 500)
        .interactiveDismissDisabled(changed || saving)
        .task { await load() }
    }

    private func load() async {
        do {
            let (volume, loaded) = try await Task.detached {
                let volume = try DiskLister.dataVolume(for: disk)
                return (volume, try ConfigurationSnapshot.load(root: volume.root))
            }.value
            guard !Task.isCancelled else { return }
            let parsed = try BootMenuValues(configuration: loaded.configuration)
            mount = volume
            snapshot = loaded
            values = parsed
            initial = parsed
        } catch {
            snapshot = nil
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    private func chooseImage() {
        guard let mount else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = mount.root
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["iso", "wim", "img", "vhd", "vhdx", "efi", "vtoy"].compactMap { UTType(filenameExtension: $0) }
        let handle: (NSApplication.ModalResponse) -> Void = { result in
            guard result == .OK, let url = panel.url else { return }
            let root = mount.root.resolvingSymlinksInPath().path + "/"
            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(root) else {
                errorMessage = "Choose an image already stored on this drive."
                return
            }
            let chosen = "/" + path.dropFirst(root.count)
            if let searchRoot = snapshot?.configuration.value("VTOY_DEFAULT_SEARCH_ROOT") {
                let folder = searchRoot.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                // Ventoy data partitions and grub path lookups are case-insensitive.
                if !folder.isEmpty,
                   chosen.range(of: "/" + folder + "/", options: [.anchored, .caseInsensitive]) == nil {
                    errorMessage = "Choose an image within this drive’s configured search folder (\(searchRoot))."
                    return
                }
            }
            values.image = chosen
            errorMessage = nil
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: handle)
        } else {
            panel.begin(completionHandler: handle)
        }
    }

    private func save() {
        guard let snapshot, let mount else { return }
        var configuration = snapshot.configuration
        if values.menuMode != initial.menuMode { configuration.set("VTOY_DEFAULT_MENU_MODE", to: values.menuMode) }
        if values.timeout != initial.timeout { configuration.set("VTOY_MENU_TIMEOUT", to: values.timeout) }
        if values.image != initial.image { configuration.set("VTOY_DEFAULT_IMAGE", to: values.image.isEmpty ? nil : values.image) }
        saving = true
        errorMessage = nil
        Task {
            do {
                try await Task.detached {
                    guard try DiskLister.dataVolume(for: disk) == mount else { throw ConfigurationError.disconnected }
                    try snapshot.save(configuration)
                }.value
                dismiss()
            } catch { errorMessage = error.localizedDescription }
            saving = false
        }
    }
}
