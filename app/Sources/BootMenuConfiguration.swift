import Foundation

/// Edits only the global controls owned by the Boot Menu sheet. Other plugins,
/// mode-specific controls and unedited values remain in the original document.
///
/// Ventoy reads only the first key of each object in the `control` array, and
/// JSON parsing does not preserve key order, so controls are normalised to one
/// key per object. Every key the user wrote is kept; each one becomes effective.
struct BootMenuConfiguration {
    static let editableKeys = ["VTOY_DEFAULT_MENU_MODE", "VTOY_MENU_TIMEOUT", "VTOY_DEFAULT_IMAGE"]
    private var document: [String: Any]
    private var controls: [(key: String, value: String)]

    init(data: Data?) throws {
        guard let data else {
            document = [:]
            controls = []
            return
        }
        let parsed: Any
        do { parsed = try JSONSerialization.jsonObject(with: data) }
        catch { throw ConfigurationError.invalidDocument }
        guard let object = parsed as? [String: Any],
              object["control"] == nil || object["control"] is [[String: String]] else {
            throw ConfigurationError.invalidDocument
        }
        document = object
        controls = (object["control"] as? [[String: String]] ?? [])
            .flatMap { $0.sorted { $0.key < $1.key } }
            .map { (key: $0.key, value: $0.value) }
        for key in Self.editableKeys {
            guard controls.filter({ $0.key == key }).count <= 1 else {
                throw ConfigurationError.invalidDocument
            }
        }
    }

    func value(_ key: String) -> String? {
        controls.first { $0.key == key }?.value
    }

    var hasModeOverrides: Bool {
        document.keys.contains { $0.hasPrefix("control_") }
    }

    mutating func set(_ key: String, to value: String?) {
        precondition(Self.editableKeys.contains(key))
        if let index = controls.firstIndex(where: { $0.key == key }) {
            if let value { controls[index].value = value } else { controls.remove(at: index) }
        } else if let value {
            controls.append((key: key, value: value))
        }
    }

    func encoded() throws -> Data {
        var result = document
        if controls.isEmpty { result.removeValue(forKey: "control") }
        else { result["control"] = controls.map { [$0.key: $0.value] } }
        return try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}

enum ConfigurationError: LocalizedError {
    case invalidDocument, changed, disconnected, unsupportedLayout, notMounted, linkedPath

    var errorDescription: String? {
        switch self {
        case .invalidDocument: return "The existing configuration could not be edited. Its contents have been left unchanged."
        case .changed: return "The configuration was changed outside this window. Close and reopen Boot Menu before saving."
        case .disconnected: return "The selected data volume is no longer mounted. Reconnect the drive and reopen Boot Menu."
        case .unsupportedLayout: return "This drive’s partition layout is not a standard Ventoy layout, so its boot menu cannot be edited here."
        case .notMounted: return "The data partition on this drive is not mounted. macOS may not support its file system; use a drive formatted as exFAT, FAT32 or NTFS."
        case .linkedPath: return "The ventoy folder or configuration file on this drive is a symbolic link, which will not be followed. Replace it with a regular folder and file."
        }
    }
}

struct ConfigurationSnapshot {
    let root: URL
    let original: Data?
    let configuration: BootMenuConfiguration

    static func load(root: URL) throws -> Self {
        let original = try read(root: root)
        return try Self(root: root, original: original, configuration: BootMenuConfiguration(data: original))
    }

    func save(_ configuration: BootMenuConfiguration) throws {
        guard try Self.read(root: root) == original else { throw ConfigurationError.changed }
        let directory = root.appendingPathComponent("ventoy", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        try configuration.encoded().write(to: directory.appendingPathComponent("ventoy.json"), options: .atomic)
    }

    private static func read(root: URL) throws -> Data? {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ConfigurationError.disconnected
        }
        let directory = root.appendingPathComponent("ventoy", isDirectory: true)
        let file = directory.appendingPathComponent("ventoy.json")
        // Removable media is untrusted: never follow a link off the drive.
        // attributesOfItem has lstat semantics, so dangling links are caught too.
        for path in [directory, file] {
            if let attributes = try? fm.attributesOfItem(atPath: path.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw ConfigurationError.linkedPath
            }
        }
        do { return try Data(contentsOf: file) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return nil
        }
    }
}
