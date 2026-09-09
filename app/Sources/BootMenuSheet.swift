import SwiftUI
import UniformTypeIdentifiers

struct BootMenuSheet: View {
    let disk: DiskInfo
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: ConfigurationSnapshot?
    @State private var mount: DataVolume?
    @State private var menuMode = "0"
    @State private var automatic = false
    @State private var delay = 10
    @State private var image = ""
    @State private var initialMode = "0"
    @State private var initialAutomatic = false
    @State private var initialDelay = 10
    @State private var initialImage = ""
    @State private var busy = true
    @State private var errorMessage: String?

    private var changed: Bool {
        menuMode != initialMode || automatic != initialAutomatic ||
        (automatic && delay != initialDelay) || image != initialImage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Boot Menu").font(.headline)
            Text(disk.parts.first?.name ?? disk.mediaName).foregroundStyle(.secondary)
            if let snapshot {
                Form {
                    Picker("Menu style", selection: $menuMode) {
                        Text("List").tag("0")
                        Text("Folders").tag("1")
                        if menuMode != "0" && menuMode != "1" {
                            Text("Current value (\(menuMode))").tag(menuMode)
                        }
                    }
                    Toggle("Boot automatically", isOn: $automatic)
                    if automatic {
                        Stepper("Delay: \(delay) seconds", value: $delay, in: 0...Int.max)
                    } else {
                        Text("Wait for an image to be selected.").foregroundStyle(.secondary)
                    }
                    LabeledContent("Default image") {
                        VStack(alignment: .trailing, spacing: 6) {
                            Text(image.isEmpty ? "First image" : image).lineLimit(2)
                                .textSelection(.enabled)
                            HStack {
                                if !image.isEmpty { Button("Use First Image") { image = "" } }
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
                    .disabled(busy)
                Button("Save Changes", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || snapshot == nil || !changed)
            }
        }
        .padding(20)
        .frame(width: 500)
        .interactiveDismissDisabled(changed || busy)
        .task { await load() }
    }

    private func load() async {
        do {
            let (volume, loaded) = try await Task.detached {
                let volume = try DiskLister.dataVolume(for: disk)
                return (volume, try ConfigurationSnapshot.load(root: volume.root))
            }.value
            mount = volume
            snapshot = loaded
            menuMode = loaded.configuration.value("VTOY_DEFAULT_MENU_MODE") ?? "0"
            let timeout = loaded.configuration.value("VTOY_MENU_TIMEOUT")
            if let timeout, Int(timeout) == nil || Int(timeout)! < 0 { throw ConfigurationError.invalidDocument }
            automatic = timeout != nil
            delay = timeout.flatMap(Int.init) ?? 10
            image = loaded.configuration.value("VTOY_DEFAULT_IMAGE") ?? ""
            initialMode = menuMode
            initialAutomatic = automatic
            initialDelay = delay
            initialImage = image
        } catch {
            snapshot = nil
            errorMessage = error.localizedDescription
        }
        busy = false
    }

    private func chooseImage() {
        guard let mount else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = mount.root
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["iso", "wim", "img", "vhd", "vhdx", "efi", "vtoy"].compactMap { UTType(filenameExtension: $0) }
        panel.begin { result in
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
                if !folder.isEmpty && !chosen.hasPrefix("/" + folder + "/") {
                    errorMessage = "Choose an image within this drive’s configured search folder (\(searchRoot))."
                    return
                }
            }
            image = chosen
            errorMessage = nil
        }
    }

    private func save() {
        guard let snapshot, let mount else { return }
        var configuration = snapshot.configuration
        if menuMode != initialMode { configuration.set("VTOY_DEFAULT_MENU_MODE", to: menuMode) }
        if automatic != initialAutomatic || (automatic && delay != initialDelay) {
            configuration.set("VTOY_MENU_TIMEOUT", to: automatic ? String(delay) : nil)
        }
        if image != initialImage { configuration.set("VTOY_DEFAULT_IMAGE", to: image.isEmpty ? nil : image) }
        busy = true
        errorMessage = nil
        Task {
            do {
                try await Task.detached {
                    guard try DiskLister.dataVolume(for: disk) == mount else { throw ConfigurationError.disconnected }
                    try snapshot.save(configuration)
                }.value
                dismiss()
            } catch { errorMessage = error.localizedDescription }
            busy = false
        }
    }
}
