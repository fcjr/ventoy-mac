import Foundation

@MainActor
final class Runner: ObservableObject {
    @Published var log = ""
    @Published var running = false
    @Published var lastSucceeded: Bool?

    private var timer: Timer?
    private var logPath = ""
    private var offset: UInt64 = 0

    func run(arguments: [String]) {
        guard !running else { return }
        guard let cli = Bundle.main.path(forResource: "ventoy2disk", ofType: nil) else {
            log = "error: ventoy2disk helper missing from app bundle\n"
            lastSucceeded = false
            return
        }
        running = true
        lastSucceeded = nil
        log = "$ ventoy2disk " + arguments.joined(separator: " ") + "\n"
        offset = 0
        logPath = NSTemporaryDirectory() + "ventoy2disk-\(getpid())-\(UInt64(Date().timeIntervalSince1970)).log"
        FileManager.default.createFile(atPath: logPath, contents: nil)

        let cmd = ([cli] + arguments).map(shellQuote).joined(separator: " ")
            + " >> " + shellQuote(logPath) + " 2>&1"
        let script = "do shell script \"\(appleScriptEscape(cmd))\" with administrator privileges"

        startPolling()
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            let errPipe = Pipe()
            p.standardOutput = FileHandle.nullDevice
            p.standardError = errPipe
            var ok = false
            var message: String?
            do {
                try p.run()
                p.waitUntilExit()
                ok = p.terminationStatus == 0
                if !ok {
                    let d = errPipe.fileHandleForReading.readDataToEndOfFile()
                    message = String(decoding: d, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } catch {
                message = error.localizedDescription
            }
            let result = (ok, message)
            await MainActor.run { self.finish(ok: result.0, errorMessage: result.1) }
        }
    }

    private func finish(ok: Bool, errorMessage: String?) {
        timer?.invalidate()
        timer = nil
        pollOnce()
        if !ok {
            if let msg = errorMessage, msg.contains("-128") {
                log += "\nCanceled.\n"
            } else {
                if let msg = errorMessage, !msg.isEmpty {
                    log += "\n" + msg + "\n"
                }
                log += "\n=== FAILED ===\n"
            }
        } else {
            log += "\n=== Done ===\n"
        }
        lastSucceeded = ok
        running = false
        try? FileManager.default.removeItem(atPath: logPath)
    }

    private func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollOnce() }
        }
    }

    private func pollOnce() {
        guard let fh = FileHandle(forReadingAtPath: logPath) else { return }
        defer { try? fh.close() }
        guard (try? fh.seek(toOffset: offset)) != nil,
              let data = try? fh.readToEnd(), !data.isEmpty else {
            return
        }
        offset += UInt64(data.count)
        log += String(decoding: data, as: UTF8.self)
    }
}

private func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func appleScriptEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}
