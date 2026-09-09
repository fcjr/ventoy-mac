import Foundation

/// Edits only the global controls owned by the Boot Menu sheet. Other plugins,
/// mode-specific controls and unedited values remain in the original document.
struct BootMenuConfiguration {
    static let editableKeys = ["VTOY_DEFAULT_MENU_MODE", "VTOY_MENU_TIMEOUT", "VTOY_DEFAULT_IMAGE"]
    private var document: [String: Any]
    private var controls: [[String: String]]

    init(data: Data?) throws {
        guard let data else {
            document = [:]
            controls = []
            return
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["control"] == nil || object["control"] is [[String: String]] else {
            throw ConfigurationError.invalidDocument
        }
        document = object
        controls = object["control"] as? [[String: String]] ?? []
        for key in Self.editableKeys {
            guard controls.filter({ $0[key] != nil }).count <= 1 else {
                throw ConfigurationError.invalidDocument
            }
        }
    }

    func value(_ key: String) -> String? {
        controls.compactMap { $0[key] }.first
    }

    var hasModeOverrides: Bool {
        document.keys.contains { $0.hasPrefix("control_") }
    }

    mutating func set(_ key: String, to value: String?) {
        precondition(Self.editableKeys.contains(key))
        if let index = controls.firstIndex(where: { $0[key] != nil }) {
            controls[index][key] = value
            if controls[index].isEmpty { controls.remove(at: index) }
        } else if let value {
            controls.append([key: value])
        }
    }

    func encoded() throws -> Data {
        var result = document
        if controls.isEmpty { result.removeValue(forKey: "control") }
        else { result["control"] = controls }
        return try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}

enum ConfigurationError: LocalizedError {
    case invalidDocument, changed, disconnected, linkedPath

    var errorDescription: String? {
        switch self {
        case .invalidDocument: return "The existing configuration could not be edited. Its contents have been left unchanged."
        case .changed: return "The configuration was changed outside this window. Close and reopen Boot Menu before saving."
        case .disconnected: return "The selected data volume is no longer mounted. Reconnect the drive and reopen Boot Menu."
        case .linkedPath: return "The configuration path contains a symbolic link. Choose a drive with a regular ventoy folder and configuration file."
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
        for path in [root, directory, file] {
            // lstat semantics also reject dangling links.
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
