import Foundation

struct DiskInfo: Identifiable, Hashable {
    let id: String
    let mediaName: String
    let size: UInt64
    let scheme: String?
    let ventoyInstalled: Bool
    let ventoyVersion: String?

    var devPath: String { "/dev/" + id }
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
            let content = d["Content"] as? String
            let scheme: String?
            switch content {
            case "GUID_partition_scheme": scheme = "GPT"
            case "FDisk_partition_scheme": scheme = "MBR"
            default: scheme = nil
            }
            let parts = d["Partitions"] as? [[String: Any]] ?? []
            var vtoyPart = parts.first { ($0["VolumeName"] as? String) == "VTOYEFI" }
            if vtoyPart == nil, parts.count == 2, scheme != nil,
               (parts[1]["Size"] as? NSNumber)?.uint64Value == 33_554_432 {
                vtoyPart = parts[1]
            }
            var version: String?
            if let pdev = vtoyPart?["DeviceIdentifier"] as? String {
                version = ventoyVersion(partition: pdev)
            }
            return DiskInfo(id: dev,
                            mediaName: mediaName(dev) ?? "External disk",
                            size: size,
                            scheme: scheme,
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

    private static func mediaName(_ dev: String) -> String? {
        guard let info = diskutilPlist(["info", "-plist", dev]) else { return nil }
        let name = (info["MediaName"] as? String) ?? (info["IORegistryEntryName"] as? String)
        return name?.trimmingCharacters(in: .whitespaces)
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
