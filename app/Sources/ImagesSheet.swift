import SwiftUI
import UniformTypeIdentifiers

struct ImagesSheet: View {
    let disk: DiskInfo
    @Environment(\.dismiss) private var dismiss
    @State private var volume: DataVolume?
    @State private var volumeError: String?
    @State private var listing = ImageListing()
    @State private var listError: String?
    @State private var loading = true
    @State private var progress = 0.0
    @State private var current: String?
    @State private var copyTask: Task<Void, Never>?
    @State private var copyErrors: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "photo.on.rectangle.angled").font(.system(size: 28)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Images on “\(disk.mediaName)”").font(.headline)
                    if let volume {
                        Text(volume.root.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    } else if let volumeError {
                        Text(volumeError).font(.caption).foregroundStyle(.red)
                    } else {
                        Text("Resolving…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            if loading {
                ProgressView().controlSize(.small)
            } else {
                List(listing.files) { file in
                    HStack {
                        Text(file.relativePath).lineLimit(1)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(height: 220)
                .overlay {
                    if listing.files.isEmpty && listError == nil && volumeError == nil {
                        Text("No boot images found").foregroundStyle(.secondary)
                    }
                }
                if let listError { Text(listError).font(.caption).foregroundStyle(.red) }
                if listing.unreadable > 0 {
                    Text("\(listing.unreadable) item(s) on this drive could not be read and are not shown.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if copyTask != nil {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: progress).progressViewStyle(.linear)
                        if let current { Text(current).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
                if !copyErrors.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(copyErrors, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
                    }
                    .frame(maxHeight: 60)
                }
            }
            HStack {
                Button("Add Images…", action: pick).disabled(volume == nil || copyTask != nil)
                if let copyTask { Button("Cancel") { copyTask.cancel() } }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).disabled(copyTask != nil)
            }
        }
        .padding(20)
        .frame(width: 560)
        .interactiveDismissDisabled(copyTask != nil)
        .task { await reload() }
        .onDisappear { copyTask?.cancel() }
    }

    private func reload() async {
        loading = true
        volumeError = nil
        listError = nil
        let resolved: DataVolume
        do {
            resolved = try await Task.detached { try DiskLister.dataVolume(for: disk) }.value
        } catch {
            volumeError = error.localizedDescription
            loading = false
            return
        }
        volume = resolved
        await refreshList(root: resolved.root, sweep: true)
        loading = false
    }

    private func refreshList(root: URL, sweep: Bool = false) async {
        do {
            listing = try await Task.detached {
                if sweep { ImageCopier.removeStaleTemporaryFiles(in: root) }
                return try ImageEnumerator.list(root: root)
            }.value
            listError = nil
        } catch {
            listError = "The drive’s contents could not be listed. " + error.localizedDescription
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = ImageEnumerator.allowed.sorted().compactMap { UTType(filenameExtension: $0) }
        panel.allowsOtherFileTypes = false
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            startCopy(panel.urls)
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func startCopy(_ urls: [URL]) {
        guard let volume else { return }
        copyErrors = []
        progress = 0
        current = urls.first?.lastPathComponent
        let disk = disk
        copyTask = Task {
            let work = Task.detached(priority: .userInitiated) {
                try await ImageCopier.copy(sources: urls, to: volume.root, validate: {
                    guard try DiskLister.dataVolume(for: disk) == volume else { throw ConfigurationError.disconnected }
                }) { fraction, name in
                    // The main queue is FIFO, so updates cannot arrive out of order.
                    DispatchQueue.main.async {
                        progress = fraction
                        current = fraction >= 1 ? "Finishing writes…" : name
                    }
                }
            }
            do {
                let result = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                copyErrors = result.failed.map { "\($0.name): \($0.message)" }
            } catch is CancellationError {
                copyErrors = ["Canceled. The partial copy was removed."]
            } catch {
                copyErrors = [error.localizedDescription]
            }
            await refreshList(root: volume.root)
            progress = 0
            current = nil
            copyTask = nil
        }
    }
}
