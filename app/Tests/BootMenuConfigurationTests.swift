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

        // A stale window cannot overwrite another save, even with valid JSON.
        do { try saved.save(enabled); preconditionFailure("accepted stale document") }
        catch ConfigurationError.changed { }
        for invalid in ["[1,2]", "{", #"{"control":{"VTOY_MENU_TIMEOUT":"5"}}"#,
                        #"{"control":[{"VTOY_MENU_TIMEOUT":"5"},{"VTOY_MENU_TIMEOUT":"6"}]}"#] {
            do { _ = try BootMenuConfiguration(data: Data(invalid.utf8)); preconditionFailure("accepted malformed controls") }
            catch { }
        }
        let linked = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: root)
        do { _ = try ConfigurationSnapshot.load(root: linked); preconditionFailure("accepted symbolic link") }
        catch ConfigurationError.linkedPath { }
        print("BootMenuConfiguration: round trips, plugin preservation, conflicts, malformed data and symlinks passed")
    }
}
