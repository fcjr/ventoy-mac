import Foundation

struct DataPartition {
    let deviceID: String
    let mountPoint: URL
    let volumeUUID: String?
}

enum ImageLibraryError: LocalizedError {
    case notMounted(String)
    case wrongParent(String)
    case isEFI(String)
    case cannotResolve(String)
    case duplicate(String)
    case isSymlink(String)
    case sameFile(String)
    case uuidMismatch
    var errorDescription: String? {
        switch self {
        case .notMounted(let d): return "\(d) data partition not mounted"
        case .wrongParent(let d): return "\(d) does not belong to selected disk"
        case .isEFI(let d): return "\(d) is the EFI partition, not data"
        case .cannotResolve(let s): return s
        case .duplicate(let n): return "\(n) already exists"
        case .isSymlink(let p): return "\(p) is a symlink"
        case .sameFile(let p): return "\(p) is already on this volume"
        case .uuidMismatch: return "Volume changed during copy"
        }
    }
}

enum DataPartitionResolver {
    static func resolve(diskID: String) throws -> DataPartition {
        let s1 = diskID + "s1"
        guard let dict = diskutilPlist(["info", "-plist", s1]) else {
            throw ImageLibraryError.cannotResolve("diskutil info failed for \(s1)")
        }
        return try parse(diskID: diskID, info: dict)
    }
    static func parse(diskID: String, info dict: [String: Any]) throws -> DataPartition {
        let s1 = diskID + "s1"
        let parent = dict["ParentWholeDisk"] as? String ?? ""
        guard parent == diskID else { throw ImageLibraryError.wrongParent(s1) }
        if let c = dict["Content"] as? String, c == "EFI" { throw ImageLibraryError.isEFI(s1) }
        // diskutil omits Mounted on some macOS versions; MountPoint is authoritative.
        guard let mp = dict["MountPoint"] as? String, !mp.isEmpty else { throw ImageLibraryError.notMounted(s1) }
        guard let uuid = dict["VolumeUUID"] as? String, !uuid.isEmpty else {
            throw ImageLibraryError.cannotResolve("Cannot identify the mounted volume. Reconnect the drive and try again.")
        }
        if (dict["VolumeName"] as? String) == "VTOYEFI" { throw ImageLibraryError.isEFI(s1) }
        return DataPartition(deviceID: s1, mountPoint: URL(fileURLWithPath: mp), volumeUUID: uuid)
    }
    static func diskutilPlist(_ args: [String]) -> [String: Any]? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil"); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}

struct BootFile: Identifiable {
    let id = UUID()
    let url: URL
    let relativePath: String
    let size: UInt64
}

enum ImageEnumerator {
    static let allowed: Set<String> = ["iso","wim","img","vhd","vhdx","efi","vtoy"]
    static func list(root: URL) throws -> [BootFile] {
        let fm = FileManager.default
        var scanError: Error?
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles], errorHandler: { _, error in scanError = error; return false }) else {
            throw ImageLibraryError.cannotResolve("Cannot read the drive.")
        }
        var out: [BootFile] = []
        for case let u as URL in en {
            let vals = try u.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            if vals.isSymbolicLink == true { en.skipDescendants(); continue }
            if vals.isRegularFile != true { continue }
            let ext = u.pathExtension.lowercased()
            if !allowed.contains(ext) { continue }
            let rel = String(u.path.dropFirst(root.path.count + 1))
            let sz = (vals.fileSize.map { UInt64($0) }) ?? 0
            out.append(BootFile(url: u, relativePath: rel, size: sz))
        }
        if let scanError { throw scanError }
        return out.sorted { $0.relativePath.lowercased() < $1.relativePath.lowercased() }
    }
}

enum ImageCopier {
    static func copy(sources: [URL], partition: DataPartition, progress: @escaping (Double, String) -> Void) async throws -> (succeeded: [String], failed: [(String, String)]) {
        try await copy(sources: sources, to: partition.mountPoint, pinnedUUID: partition.volumeUUID, deviceID: partition.deviceID, progress: progress)
    }
    static func copy(sources: [URL], to root: URL, pinnedUUID: String?, deviceID: String? = nil, progress: @escaping (Double, String) -> Void) async throws -> (succeeded: [String], failed: [(String, String)]) {
        func validateVolume() throws {
            guard let deviceID else { return } // Temporary-folder tests have no disk identifier.
            guard let pinnedUUID, let current = DataPartitionResolver.diskutilPlist(["info", "-plist", deviceID]),
                  current["VolumeUUID"] as? String == pinnedUUID,
                  current["MountPoint"] as? String == root.path else { throw ImageLibraryError.uuidMismatch }
        }
        try Task.checkCancellation()
        try validateVolume()
        let fm = FileManager.default
        var succeeded: [String] = []
        var failed: [(String, String)] = []
        var total: UInt64 = 0
        for s in sources { total += (try? fm.attributesOfItem(atPath: s.path)[.size] as? UInt64) ?? 0 }
        var copiedOverall: UInt64 = 0
        for src in sources {
            try Task.checkCancellation()
            let name = src.lastPathComponent
            let finalURL = root.appendingPathComponent(name)
            var tmpURL: URL? = nil
            var didCreateTmp = false
            do {
                try validateVolume()
                let attrs = try fm.attributesOfItem(atPath: src.path)
                guard attrs[.type] as? FileAttributeType == .typeRegular,
                      ImageEnumerator.allowed.contains(src.pathExtension.lowercased()) else {
                    throw ImageLibraryError.cannotResolve("Choose a regular boot image file: \(name)")
                }
                if (try? src.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { throw ImageLibraryError.isSymlink(src.path) }
                if src.resolvingSymlinksInPath().standardizedFileURL.path == finalURL.resolvingSymlinksInPath().standardizedFileURL.path { throw ImageLibraryError.sameFile(name) }
                if fm.fileExists(atPath: finalURL.path) { throw ImageLibraryError.duplicate(name) }
                let tmp = root.appendingPathComponent(".ventoy.\(name).\(UUID().uuidString).tmp")
                tmpURL = tmp
                guard let r = FileHandle(forReadingAtPath: src.path) else { throw ImageLibraryError.cannotResolve("cannot open \(name)") }
                guard fm.createFile(atPath: tmp.path, contents: nil) else {
                    try? r.close()
                    throw ImageLibraryError.cannotResolve("Cannot create a file on this drive.")
                }
                didCreateTmp = true
                guard let w = FileHandle(forWritingAtPath: tmp.path) else { try? r.close(); if let t = tmpURL, didCreateTmp { try? fm.removeItem(at: t) }; throw ImageLibraryError.cannotResolve("cannot create temp for \(name)") }
                do {
                    let buf = 1024*1024
                    while true {
                        try Task.checkCancellation()
                        guard let data = try r.read(upToCount: buf), !data.isEmpty else { break }
                        try w.write(contentsOf: data)
                        copiedOverall += UInt64(data.count)
                        progress(total > 0 ? Double(copiedOverall)/Double(total) : 0, name)
                    }
                    try w.synchronize()
                } catch is CancellationError { try? r.close(); try? w.close(); if let t = tmpURL, didCreateTmp { try? fm.removeItem(at: t) }; throw CancellationError() }
                catch { if let t = tmpURL, didCreateTmp { try? fm.removeItem(at: t) }; try? r.close(); try? w.close(); throw error }
                try? r.close(); try? w.close()
                try Task.checkCancellation()
                try validateVolume()
                do { try fm.moveItem(at: tmp, to: finalURL) } catch { if let t = tmpURL, didCreateTmp { try? fm.removeItem(at: t) }; throw error }
                didCreateTmp = false; tmpURL = nil
                succeeded.append(name)
            } catch is CancellationError {
                if let t = tmpURL, didCreateTmp { try? fm.removeItem(at: t) }
                throw CancellationError()
            } catch {
                if let t = tmpURL, didCreateTmp { try? fm.removeItem(at: t) }
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                failed.append((name, msg))
                if Task.isCancelled { throw CancellationError() }
            }
        }
        return (succeeded, failed)
    }
}
