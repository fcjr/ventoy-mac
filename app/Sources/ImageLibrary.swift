import Foundation

enum ImageLibraryError: LocalizedError {
    case notBootImage(String)
    case isSymlink(String)
    case sameFile(String)
    case duplicate(String)
    case cannotOpen(String)
    case cannotWrite(String)

    var errorDescription: String? {
        switch self {
        case .notBootImage(let n): return "\(n) is not a boot image file."
        case .isSymlink(let n): return "\(n) is a symbolic link. Choose the file it points to."
        case .sameFile(let n): return "\(n) is already on this drive."
        case .duplicate(let n): return "\(n) already exists on this drive."
        case .cannotOpen(let n): return "\(n) could not be opened."
        case .cannotWrite(let n): return "\(n) could not be written to this drive."
        }
    }
}

struct BootFile: Identifiable {
    let url: URL
    let relativePath: String
    let size: UInt64
    var id: String { relativePath }
}

struct ImageListing {
    var files: [BootFile] = []
    /// Entries skipped because macOS could not read them; the rest still list.
    var unreadable = 0
}

enum ImageEnumerator {
    static let allowed: Set<String> = ["iso", "wim", "img", "vhd", "vhdx", "efi", "vtoy"]

    static func list(root: URL) throws -> ImageListing {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        var listing = ImageListing()
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles],
            errorHandler: { _, _ in listing.unreadable += 1; return true }) else {
            throw CocoaError(.fileReadUnknown)
        }
        let prefix = root.standardizedFileURL.path + "/"
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys) else { listing.unreadable += 1; continue }
            // Never follow links: a link could lead off the drive. The enumerator
            // does not descend into linked directories, so skipping the entry is enough.
            if values.isSymbolicLink == true { continue }
            guard values.isRegularFile == true, allowed.contains(url.pathExtension.lowercased()) else { continue }
            let path = url.standardizedFileURL.path
            let relative = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : url.lastPathComponent
            listing.files.append(BootFile(url: url, relativePath: relative, size: UInt64(values.fileSize ?? 0)))
        }
        listing.files.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        return listing
    }
}

struct CopyResult {
    var succeeded: [String] = []
    var failed: [(name: String, message: String)] = []
}

enum ImageCopier {
    private static let temporaryPrefix = ".ventoy."
    private static let temporarySuffix = ".tmp"
    private static let chunk = 1 << 20

    /// Copies each source into `root` under its own name. `validate` runs before
    /// each file and again before it is moved into place, so the caller can
    /// confirm the destination volume is still the one the user picked.
    /// Progress is reported at most every half percent plus once per file.
    static func copy(sources: [URL], to root: URL,
                     validate: () throws -> Void = {},
                     progress: (Double, String) -> Void) async throws -> CopyResult {
        try Task.checkCancellation()
        try validate()
        var result = CopyResult()
        let sizes = sources.map { (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? UInt64) ?? 0 }
        var total = sizes.reduce(0, +)
        var copied: UInt64 = 0
        var lastReported = -1.0
        func report(_ name: String, force: Bool) {
            let fraction = total > 0 ? min(Double(copied) / Double(total), 1) : 1
            if force || fraction - lastReported >= 0.005 {
                lastReported = fraction
                progress(fraction, name)
            }
        }
        for (source, size) in zip(sources, sizes) {
            try Task.checkCancellation()
            let name = source.lastPathComponent
            var copiedThisFile: UInt64 = 0
            report(name, force: true)
            do {
                try validate()
                try copyOne(source, named: name, to: root, validate: validate) { bytes in
                    copiedThisFile += UInt64(bytes)
                    copied += UInt64(bytes)
                    report(name, force: false)
                }
                result.succeeded.append(name)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Drop the failed file from the denominator so the bar can still reach the end.
                copied -= copiedThisFile
                total -= size
                report(name, force: true)
                result.failed.append((name, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            }
        }
        return result
    }

    private static func copyOne(_ source: URL, named name: String, to root: URL,
                                validate: () throws -> Void, onChunk: (Int) -> Void) throws {
        let fm = FileManager.default
        // attributesOfItem has lstat semantics, so a link is reported as a link.
        switch try fm.attributesOfItem(atPath: source.path)[.type] as? FileAttributeType {
        case .typeSymbolicLink: throw ImageLibraryError.isSymlink(name)
        case .typeRegular: break
        default: throw ImageLibraryError.notBootImage(name)
        }
        guard ImageEnumerator.allowed.contains(source.pathExtension.lowercased()) else {
            throw ImageLibraryError.notBootImage(name)
        }
        let destination = root.appendingPathComponent(name)
        if source.resolvingSymlinksInPath().standardizedFileURL.path == destination.resolvingSymlinksInPath().standardizedFileURL.path {
            throw ImageLibraryError.sameFile(name)
        }
        if fm.fileExists(atPath: destination.path) { throw ImageLibraryError.duplicate(name) }

        guard let reader = FileHandle(forReadingAtPath: source.path) else { throw ImageLibraryError.cannotOpen(name) }
        defer { try? reader.close() }
        let temporary = root.appendingPathComponent(temporaryPrefix + name + "." + UUID().uuidString + temporarySuffix)
        guard fm.createFile(atPath: temporary.path, contents: nil),
              let writer = FileHandle(forWritingAtPath: temporary.path) else {
            throw ImageLibraryError.cannotWrite(name)
        }
        var moved = false
        defer {
            try? writer.close()
            if !moved { try? fm.removeItem(at: temporary) }
        }
        while true {
            try Task.checkCancellation()
            guard let data = try reader.read(upToCount: chunk), !data.isEmpty else { break }
            try writer.write(contentsOf: data)
            onChunk(data.count)
        }
        try writer.synchronize()
        try Task.checkCancellation()
        try validate()
        // moveItem refuses to replace an existing file, so a race cannot clobber one.
        try fm.moveItem(at: temporary, to: destination)
        moved = true
    }

    /// Removes temporary files left in `root` by a copy that never finished,
    /// such as after a crash or power loss. They are hidden, so the listing
    /// would otherwise never show them.
    static func removeStaleTemporaryFiles(in root: URL) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        for name in names where name.hasPrefix(temporaryPrefix) && name.hasSuffix(temporarySuffix) {
            let path = root.appendingPathComponent(name).path
            guard (try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeRegular else { continue }
            try? fm.removeItem(atPath: path)
        }
    }
}
