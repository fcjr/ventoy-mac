import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ImagesSheet: View {
    let disk: DiskInfo
    @Environment(\.dismiss) private var dismiss
    @State private var part: DataPartition?
    @State private var resolveError: String?
    @State private var files: [BootFile] = []
    @State private var listError: String?
    @State private var loading = true
    @State private var prog: Double = 0
    @State private var cur: String?
    @State private var task: Task<Void,Never>?
    @State private var copyErrors: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "photo.on.rectangle.angled").font(.system(size: 28)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Images on “\(disk.mediaName)”").font(.headline)
                    if let p = part { Text(p.mountPoint.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    else if let e = resolveError { Text(e).font(.caption).foregroundStyle(.red) }
                    else { Text("Resolving…").font(.caption).foregroundStyle(.secondary) }
                }; Spacer()
            }
            if loading { ProgressView().controlSize(.small) }
            else {
                List { ForEach(files) { f in HStack { Text(f.relativePath).lineLimit(1); Spacer(); Text(ByteCountFormatter.string(fromByteCount: Int64(f.size), countStyle: .file)).font(.caption).foregroundStyle(.secondary) } } }
                .frame(height: 220)
                .overlay { if files.isEmpty && listError == nil && resolveError == nil { Text("No boot images found").foregroundStyle(.secondary) } }
                if let e = listError { Text(e).font(.caption).foregroundStyle(.red) }
                if task != nil {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: prog).progressViewStyle(.linear)
                        if let c = cur { Text(c).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
                if !copyErrors.isEmpty {
                    VStack(alignment: .leading, spacing: 2) { ForEach(copyErrors, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) } }
                    .frame(maxHeight: 60)
                }
            }
            HStack {
                Button("Add Images…") { pick() }.disabled(part == nil || task != nil)
                if let t = task { Button("Cancel") { t.cancel() } }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).disabled(task != nil)
            }
        }
        .padding(20).frame(width: 560)
        .interactiveDismissDisabled(task != nil)
        .onAppear { reload() }
        .onDisappear { task?.cancel() }
    }

    private func reload() {
        loading = true; part = nil; resolveError = nil; listError = nil
        let id = disk.id
        Task.detached {
            do {
                let p = try DataPartitionResolver.resolve(diskID: id)
                let list = try ImageEnumerator.list(root: p.mountPoint)
                await MainActor.run { self.part = p; self.files = list; self.loading = false }
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run {
                    self.resolveError = msg
                    self.loading = false
                }
            }
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        let exts = ["iso","wim","img","vhd","vhdx","efi","vtoy"]
        panel.allowedContentTypes = exts.compactMap { UTType(filenameExtension: $0) }
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
        copyErrors = []; prog = 0; cur = urls.first?.lastPathComponent
        guard let p = part else { return }
        let pinned = p
        task = Task {
            do {
                let copyTask = Task.detached(priority: .userInitiated) {
                    try await ImageCopier.copy(sources: urls, partition: pinned) { v, n in
                        Task { @MainActor in self.prog = min(v, 1); self.cur = v >= 1 ? "Finishing writes…" : n }
                    }
                }
                let res = try await withTaskCancellationHandler {
                    try await copyTask.value
                } onCancel: { copyTask.cancel() }
                await MainActor.run {
                    if !res.failed.isEmpty { self.copyErrors = res.failed.map { "\($0.0): \($0.1)" } }
                    else if !res.succeeded.isEmpty { self.copyErrors = [] }
                    self.prog = 0
                }
                await refreshList(root: pinned.mountPoint)
            } catch is CancellationError {
                await MainActor.run { self.copyErrors.append("Canceled – partial copy removed"); self.prog = 0 }
                await refreshList(root: pinned.mountPoint)
            } catch {
                await MainActor.run { self.copyErrors.append(error.localizedDescription) }
            }
            await MainActor.run { self.task = nil; self.cur = nil }
        }
    }

    private func refreshList(root: URL) async {
        do {
            let r = try await Task.detached { try ImageEnumerator.list(root: root) }.value
            await MainActor.run { self.files = r; self.listError = nil }
        } catch {
            await MainActor.run { self.listError = error.localizedDescription }
        }
    }
}
