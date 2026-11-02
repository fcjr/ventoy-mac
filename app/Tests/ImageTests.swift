import Foundation

func makeTempDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("vtoy-test-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}
func writeFile(at url: URL, size: Int, byte: UInt8 = 0xAB) throws {
    try Data(repeating: byte, count: size).write(to: url)
}
func assert(_ cond: Bool, _ msg: String) { if !cond { print("FAIL \(msg)"); exit(1) } }

func testRoundTrip() async {
    let srcDir = makeTempDir(); let dstDir = makeTempDir()
    defer { try? FileManager.default.removeItem(at: srcDir); try? FileManager.default.removeItem(at: dstDir) }
    let src = srcDir.appendingPathComponent("a.iso")
    try! writeFile(at: src, size: 2_000_000)
    var last = -1.0
    let res = try! await ImageCopier.copy(sources: [src], to: dstDir) { v, _ in last = v }
    assert(res.succeeded == ["a.iso"], "roundtrip succeeded")
    assert(res.failed.isEmpty, "roundtrip no failed")
    assert(last == 1, "progress reaches 1")
    let dst = dstDir.appendingPathComponent("a.iso")
    assert(try! Data(contentsOf: src) == Data(contentsOf: dst), "content equal")
    let temps = (try? FileManager.default.contentsOfDirectory(atPath: dstDir.path))?.filter { $0.hasSuffix(".tmp") } ?? []
    assert(temps.isEmpty, "no tmp left")
    print("PASS roundTrip")
}

func testDuplicate() async {
    let srcDir = makeTempDir(); let dstDir = makeTempDir()
    defer { try? FileManager.default.removeItem(at: srcDir); try? FileManager.default.removeItem(at: dstDir) }
    let good = srcDir.appendingPathComponent("good.iso")
    try! writeFile(at: good, size: 1_500_000)
    let src = srcDir.appendingPathComponent("dup.iso")
    try! writeFile(at: src, size: 1_500_000, byte: 0x11)
    let dst = dstDir.appendingPathComponent("dup.iso")
    try! writeFile(at: dst, size: 1000, byte: 0x22)
    let orig = try! Data(contentsOf: dst)
    var last = -1.0
    let res = try! await ImageCopier.copy(sources: [good, src], to: dstDir) { v, _ in last = v }
    assert(res.succeeded == ["good.iso"], "duplicate only good copied")
    assert(res.failed.count == 1, "duplicate one failed")
    assert(try! Data(contentsOf: dst) == orig, "duplicate preserved")
    // A skipped file leaves the denominator, so the bar still finishes.
    assert(last == 1, "progress reaches 1 after a skipped file, got \(last)")
    print("PASS duplicate")
}

func testSymlink() async {
    let srcDir = makeTempDir(); let dstDir = makeTempDir()
    defer { try? FileManager.default.removeItem(at: srcDir); try? FileManager.default.removeItem(at: dstDir) }
    let real = srcDir.appendingPathComponent("real.iso")
    try! writeFile(at: real, size: 500)
    let link = srcDir.appendingPathComponent("link.iso")
    try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    let res = try! await ImageCopier.copy(sources: [link], to: dstDir) { _, _ in }
    assert(res.succeeded.isEmpty, "symlink no success")
    assert(res.failed.first?.message.contains("symbolic link") == true, "symlink reports the link error")
    assert(!FileManager.default.fileExists(atPath: dstDir.appendingPathComponent("link.iso").path), "symlink not copied")
    print("PASS symlink")
}

func testSameFile() async {
    let dir = makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let src = dir.appendingPathComponent("same.iso")
    try! writeFile(at: src, size: 400)
    let res = try! await ImageCopier.copy(sources: [src], to: dir) { _, _ in }
    assert(res.failed.count == 1, "sameFile failed")
    print("PASS sameFile")
}

final class TaskBox: @unchecked Sendable { var task: Task<CopyResult, Error>? }

func testCancellation() async {
    let srcDir = makeTempDir(); let dstDir = makeTempDir()
    defer { try? FileManager.default.removeItem(at: srcDir); try? FileManager.default.removeItem(at: dstDir) }
    let src = srcDir.appendingPathComponent("big.iso")
    try! writeFile(at: src, size: 30_000_000)
    // Cancel from inside the first progress report, so the copy is guaranteed
    // to still be running when cancellation lands.
    let box = TaskBox()
    box.task = Task {
        try await ImageCopier.copy(sources: [src], to: dstDir) { _, _ in box.task?.cancel() }
    }
    do { _ = try await box.task!.value; print("FAIL cancellation not thrown"); exit(1) }
    catch is CancellationError {
        assert(!FileManager.default.fileExists(atPath: dstDir.appendingPathComponent("big.iso").path), "cancel no final")
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
    try! writeFile(at: dir.appendingPathComponent(".ventoy.x.iso.tmp"), size: 10)
    let elsewhere = makeTempDir()
    defer { try? FileManager.default.removeItem(at: elsewhere) }
    try! writeFile(at: elsewhere.appendingPathComponent("z.iso"), size: 10)
    try! FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("outside"), withDestinationURL: elsewhere)
    try! FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link.iso"), withDestinationURL: dir.appendingPathComponent("a.iso"))
    let list = try! ImageEnumerator.list(root: dir)
    let names = Set(list.files.map { $0.relativePath })
    assert(names == ["a.iso", "sub/c.vhd"], "enumerator lists images with relative paths, got \(names)")
    print("PASS enumerator")
}

func testEnumeratorToleratesUnreadable() {
    let dir = makeTempDir()
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent("locked").path); try? FileManager.default.removeItem(at: dir) }
    try! writeFile(at: dir.appendingPathComponent("a.iso"), size: 10)
    let locked = dir.appendingPathComponent("locked")
    try! FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
    try! writeFile(at: locked.appendingPathComponent("hidden.iso"), size: 10)
    try! FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
    let list = try! ImageEnumerator.list(root: dir)
    assert(list.files.map { $0.relativePath } == ["a.iso"], "readable files still listed")
    if geteuid() != 0 { assert(list.unreadable > 0, "unreadable directory is counted") }
    print("PASS enumeratorToleratesUnreadable")
}

func testStaleTemporarySweep() {
    let dir = makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try! writeFile(at: dir.appendingPathComponent(".ventoy.a.iso.1234.tmp"), size: 10)
    try! writeFile(at: dir.appendingPathComponent(".hidden.iso"), size: 10)
    try! writeFile(at: dir.appendingPathComponent("keep.tmp"), size: 10)
    ImageCopier.removeStaleTemporaryFiles(in: dir)
    let left = Set(try! FileManager.default.contentsOfDirectory(atPath: dir.path))
    assert(left == [".hidden.iso", "keep.tmp"], "only ventoy temp files are swept, got \(left)")
    print("PASS staleTemporarySweep")
}

struct VolumeGone: Error {}

func testValidationFailsClosed() async {
    let srcDir = makeTempDir(); let dstDir = makeTempDir()
    defer { try? FileManager.default.removeItem(at: srcDir); try? FileManager.default.removeItem(at: dstDir) }
    let src = srcDir.appendingPathComponent("a.iso")
    try! writeFile(at: src, size: 100)
    do {
        _ = try await ImageCopier.copy(sources: [src], to: dstDir, validate: { throw VolumeGone() }) { _, _ in }
        assert(false, "disconnected volume must fail closed")
    } catch is VolumeGone {
        assert(!FileManager.default.fileExists(atPath: dstDir.appendingPathComponent("a.iso").path), "nothing written")
        print("PASS validationFailsClosed")
    } catch { assert(false, "unexpected volume error: \(error)") }
}

@main struct Runner {
    static func main() async {
        testEnumerator()
        testEnumeratorToleratesUnreadable()
        testStaleTemporarySweep()
        await testRoundTrip()
        await testDuplicate()
        await testSymlink()
        await testSameFile()
        await testCancellation()
        await testValidationFailsClosed()
        print("ALL PASS")
    }
}
