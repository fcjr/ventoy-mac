import Foundation

func makeTempDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("vtoy-test-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}
func writeFile(at url: URL, size: Int, byte: UInt8 = 0xAB) throws {
    let data = Data(repeating: byte, count: size)
    try data.write(to: url)
}
func assert(_ cond: Bool, _ msg: String) { if !cond { print("FAIL \(msg)"); exit(1) } }

func testRoundTrip() async {
    let srcDir = makeTempDir(); let dstDir = makeTempDir()
    defer { try? FileManager.default.removeItem(at: srcDir); try? FileManager.default.removeItem(at: dstDir) }
    let src = srcDir.appendingPathComponent("a.iso")
    try! writeFile(at: src, size: 2_000_000)
    let res = try! await ImageCopier.copy(sources: [src], to: dstDir, pinnedUUID: nil) { _,_ in }
    assert(res.succeeded == ["a.iso"], "roundtrip succeeded")
    assert(res.failed.isEmpty, "roundtrip no failed")
    let dst = dstDir.appendingPathComponent("a.iso")
    assert(FileManager.default.fileExists(atPath: dst.path), "dst exists")
    let a = try! Data(contentsOf: src); let b = try! Data(contentsOf: dst)
    assert(a == b, "content equal")
    let temps = (try? FileManager.default.contentsOfDirectory(atPath: dstDir.path))?.filter { $0.hasSuffix(".tmp") } ?? []
    assert(temps.isEmpty, "no tmp left")
    print("PASS roundTrip")
}

func testDuplicate() async {
    let srcDir = makeTempDir(); let dstDir = makeTempDir()
    defer { try? FileManager.default.removeItem(at: srcDir); try? FileManager.default.removeItem(at: dstDir) }
    let src = srcDir.appendingPathComponent("dup.iso")
    try! writeFile(at: src, size: 1000, byte: 0x11)
    let dst = dstDir.appendingPathComponent("dup.iso")
    try! writeFile(at: dst, size: 1000, byte: 0x22)
    let orig = try! Data(contentsOf: dst)
    let res = try! await ImageCopier.copy(sources: [src], to: dstDir, pinnedUUID: nil) { _,_ in }
    assert(res.succeeded.isEmpty, "duplicate no success")
    assert(res.failed.count == 1, "duplicate one failed")
    let after = try! Data(contentsOf: dst)
    assert(after == orig, "duplicate preserved")
    print("PASS duplicate")
}

func testSymlink() async {
    let srcDir = makeTempDir(); let dstDir = makeTempDir()
    defer { try? FileManager.default.removeItem(at: srcDir); try? FileManager.default.removeItem(at: dstDir) }
    let real = srcDir.appendingPathComponent("real.iso")
    try! writeFile(at: real, size: 500)
    let link = srcDir.appendingPathComponent("link.iso")
    try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    let res = try! await ImageCopier.copy(sources: [link], to: dstDir, pinnedUUID: nil) { _,_ in }
    assert(res.succeeded.isEmpty, "symlink no success")
    assert(!FileManager.default.fileExists(atPath: dstDir.appendingPathComponent("link.iso").path), "symlink not copied")
    print("PASS symlink")
}

func testSameFile() async {
    let dir = makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let src = dir.appendingPathComponent("same.iso")
    try! writeFile(at: src, size: 400)
    let res = try! await ImageCopier.copy(sources: [src], to: dir, pinnedUUID: nil) { _,_ in }
    assert(res.failed.count == 1, "sameFile failed")
    print("PASS sameFile")
}

func testCancellation() async {
    let srcDir = makeTempDir(); let dstDir = makeTempDir()
    defer { try? FileManager.default.removeItem(at: srcDir); try? FileManager.default.removeItem(at: dstDir) }
    let src = srcDir.appendingPathComponent("big.iso")
    try! writeFile(at: src, size: 30_000_000)
    let t = Task {
        try await ImageCopier.copy(sources: [src], to: dstDir, pinnedUUID: nil) { _,_ in
            // slow down a bit to allow cancellation
            Thread.sleep(forTimeInterval: 0.001)
        }
    }
    // cancel quickly
    try? await Task.sleep(nanoseconds: 20_000_000)
    t.cancel()
    do { _ = try await t.value; print("FAIL cancellation not thrown"); exit(1) }
    catch is CancellationError {
        let exists = FileManager.default.fileExists(atPath: dstDir.appendingPathComponent("big.iso").path)
        assert(!exists, "cancel no final")
        let temps = (try? FileManager.default.contentsOfDirectory(atPath: dstDir.path))?.filter { $0.contains(".ventoy.") } ?? []
        assert(temps.isEmpty, "cancel cleaned tmp")
        print("PASS cancellation")
    } catch { print("FAIL cancellation wrong error \(error)"); exit(1) }
}

func testEnumerator() {
    let dir = makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let sub = dir.appendingPathComponent("sub"); try! FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    try! writeFile(at: dir.appendingPathComponent("a.iso"), size: 10)
    try! writeFile(at: dir.appendingPathComponent("b.txt"), size: 10)
    try! writeFile(at: sub.appendingPathComponent("c.vhd"), size: 10)
    let list = try! ImageEnumerator.list(root: dir)
    let names = Set(list.map { $0.url.lastPathComponent })
    assert(names.contains("a.iso"), "enum iso")
    assert(names.contains("c.vhd"), "enum vhd")
    assert(!names.contains("b.txt"), "enum filtered")
    print("PASS enumerator")
}

func testMissingVolume() async {
    let dir = makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    do {
        _ = try await ImageCopier.copy(sources: [], to: dir, pinnedUUID: "missing", deviceID: "nonexistent-test-device") { _, _ in }
        assert(false, "disconnected volume must fail closed")
    } catch ImageLibraryError.uuidMismatch { print("PASS disconnectedVolume") }
    catch { assert(false, "unexpected volume error: \(error)") }
}

func testMountInfo() {
    var info: [String: Any] = ["ParentWholeDisk": "diskTest", "MountPoint": "/Volumes/Test", "VolumeUUID": "test-uuid"]
    let part = try! DataPartitionResolver.parse(diskID: "diskTest", info: info)
    assert(part.mountPoint.path == "/Volumes/Test", "mounted volume without Mounted Boolean")
    info.removeValue(forKey: "MountPoint")
    do { _ = try DataPartitionResolver.parse(diskID: "diskTest", info: info); assert(false, "unmounted rejected") }
    catch ImageLibraryError.notMounted { print("PASS mountInfo") }
    catch { assert(false, "unexpected mount error") }
}

@main struct Runner { static func main() async { testMountInfo(); testEnumerator(); await testRoundTrip(); await testDuplicate(); await testSymlink(); await testSameFile(); await testCancellation(); await testMissingVolume(); print("ALL PASS") } }
