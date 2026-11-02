import Foundation

@main
struct BootMenuConfigurationTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        // Saving a new configuration creates the folder, and turning automatic
        // boot off must survive loading the saved file again.
        let empty = try ConfigurationSnapshot.load(root: root)
        var enabled = empty.configuration
        enabled.set("VTOY_MENU_TIMEOUT", to: "12")
        enabled.set("VTOY_DEFAULT_IMAGE", to: "/ISO/Windows image.iso")
        try empty.save(enabled)
        let saved = try ConfigurationSnapshot.load(root: root)
        precondition(saved.configuration.value("VTOY_MENU_TIMEOUT") == "12")
        var disabled = saved.configuration
        disabled.set("VTOY_MENU_TIMEOUT", to: nil)
        try saved.save(disabled)
        let reopened = try ConfigurationSnapshot.load(root: root)
        precondition(reopened.configuration.value("VTOY_MENU_TIMEOUT") == nil)
        precondition(reopened.configuration.value("VTOY_DEFAULT_IMAGE") == "/ISO/Windows image.iso")

        let advanced = Data(#"{"control":[{"VTOY_MENU_TIMEOUT":"5","UNRECOGNIZED":"keep"}],"control_uefi":[{"VTOY_MENU_TIMEOUT":"20"}],"theme":{"file":["/theme/a.txt","/theme/b.txt"]},"persistence":[{"image":"/linux.iso","backend":["/data/a.dat"]}]}"#.utf8)
        var configuration = try BootMenuConfiguration(data: advanced)
        configuration.set("VTOY_MENU_TIMEOUT", to: nil)
        let object = try JSONSerialization.jsonObject(with: configuration.encoded()) as! [String: Any]
        let original = try JSONSerialization.jsonObject(with: advanced) as! [String: Any]
        for key in ["control_uefi", "theme", "persistence"] {
            precondition(NSDictionary(dictionary: [key: object[key]!]).isEqual(to: [key: original[key]!]))
        }
        precondition(configuration.value("UNRECOGNIZED") == "keep")

        // Ventoy honours only the first key of each control object, so edits must
        // land in objects of their own rather than inside a multi-key object.
        var split = try BootMenuConfiguration(data: advanced)
        split.set("VTOY_DEFAULT_MENU_MODE", to: "1")
        let controls = (try JSONSerialization.jsonObject(with: split.encoded()) as! [String: Any])["control"] as! [[String: String]]
        precondition(controls.allSatisfy { $0.count == 1 }, "control objects must hold a single key")
        precondition(controls.contains(["VTOY_MENU_TIMEOUT": "5"]) && controls.contains(["UNRECOGNIZED": "keep"]) && controls.contains(["VTOY_DEFAULT_MENU_MODE": "1"]))

        // A stale window cannot overwrite another save, even with valid JSON.
        do { try saved.save(enabled); preconditionFailure("accepted stale document") }
        catch ConfigurationError.changed { }
        for invalid in ["", "[1,2]", "{", "{,}", #"{"control":{"VTOY_MENU_TIMEOUT":"5"}}"#,
                        #"{"control":[{"VTOY_MENU_TIMEOUT":"5"},{"VTOY_MENU_TIMEOUT":"6"}]}"#] {
            do { _ = try BootMenuConfiguration(data: Data(invalid.utf8)); preconditionFailure("accepted malformed controls") }
            catch ConfigurationError.invalidDocument { }
        }
        // The ventoy folder and file on removable media must not be links.
        let linkedRoot = root.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: linkedRoot, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: linkedRoot.appendingPathComponent("ventoy"),
                                                   withDestinationURL: root.appendingPathComponent("ventoy"))
        do { _ = try ConfigurationSnapshot.load(root: linkedRoot); preconditionFailure("accepted symbolic link") }
        catch ConfigurationError.linkedPath { }
        try FileManager.default.removeItem(at: linkedRoot.appendingPathComponent("ventoy"))
        try FileManager.default.createDirectory(at: linkedRoot.appendingPathComponent("ventoy"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: linkedRoot.appendingPathComponent("ventoy/ventoy.json"),
                                                   withDestinationURL: root.appendingPathComponent("ventoy/ventoy.json"))
        do { _ = try ConfigurationSnapshot.load(root: linkedRoot); preconditionFailure("accepted symbolic link") }
        catch ConfigurationError.linkedPath { }
        print("BootMenuConfiguration: round trips, plugin preservation, single-key controls, conflicts, malformed data and symlinks passed")
    }
}
