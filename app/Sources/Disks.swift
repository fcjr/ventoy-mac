import Foundation

struct PartSlice: Hashable, Identifiable {
    let id: String
    let name: String?
    let size: UInt64
    let content: String?
}

struct DiskInfo: Identifiable, Hashable {
    let id: String
    let mediaName: String
    let size: UInt64
    let scheme: String?
    let parts: [PartSlice]
    let ventoyInstalled: Bool
    let ventoyVersion: String?

    var devPath: String { "/dev/" + id }
    var sectorCount: UInt64 { size / 512 }
    var sizeString: String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

enum DiskLister {
    static func externalDisks() -> [DiskInfo] {
        guard let dict = diskutilPlist(["list", "-plist", "external"]),
              let disks = dict["AllDisksAndPartitions"] as? [[String: Any]] else {
            return []
        }
        return disks.compactMap { d in
            guard let dev = d["DeviceIdentifier"] as? String,
                  let size = (d["Size"] as? NSNumber)?.uint64Value else {
                return nil
            }
            guard let info = diskutilPlist(["info", "-plist", dev]),
                  (info["Internal"] as? Bool) != true else {
                return nil
            }
            if (info["VirtualOrPhysical"] as? String) == "Virtual",
               !UserDefaults.standard.bool(forKey: "ShowVirtualDisks") {
                return nil
            }
            let content = d["Content"] as? String
            let scheme: String?
            switch content {
            case "GUID_partition_scheme": scheme = "GPT"
            case "FDisk_partition_scheme": scheme = "MBR"
            default: scheme = nil
            }
            let rawParts = d["Partitions"] as? [[String: Any]] ?? []
            let slices: [PartSlice] = rawParts.enumerated().compactMap { i, p in
                guard let psize = (p["Size"] as? NSNumber)?.uint64Value else { return nil }
                return PartSlice(id: (p["DeviceIdentifier"] as? String) ?? "\(dev)p\(i)",
                                 name: p["VolumeName"] as? String,
                                 size: psize,
                                 content: p["Content"] as? String)
            }
            var vtoyPart = slices.first { $0.name == "VTOYEFI" }
            if vtoyPart == nil, slices.count == 2, scheme != nil,
               slices[1].size == 33_554_432 {
                vtoyPart = slices[1]
            }
            var version: String?
            if let vp = vtoyPart {
                version = ventoyVersion(partition: vp.id)
            }
            let name = ((info["MediaName"] as? String)
                        ?? (info["IORegistryEntryName"] as? String))?
                .trimmingCharacters(in: .whitespaces)
            return DiskInfo(id: dev,
                            mediaName: (name?.isEmpty == false ? name! : "External disk"),
                            size: size,
                            scheme: scheme,
                            parts: slices,
                            ventoyInstalled: vtoyPart != nil,
                            ventoyVersion: version)
        }
    }

    static func latestReleaseTag() async -> String? {
        guard let url = URL(string: "https://api.github.com/repos/ventoy/Ventoy/releases/latest") else {
            return nil
        }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String else {
            return nil
        }
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    private static func ventoyVersion(partition: String) -> String? {
        guard let info = diskutilPlist(["info", "-plist", partition]),
              let mp = info["MountPoint"] as? String, !mp.isEmpty,
              let cfg = try? String(contentsOfFile: mp + "/grub/grub.cfg", encoding: .utf8),
              let start = cfg.range(of: "VENTOY_VERSION=\"") else {
            return nil
        }
        let rest = cfg[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    private static func diskutilPlist(_ args: [String]) -> [String: Any]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}
