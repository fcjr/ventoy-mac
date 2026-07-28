import Foundation
import Security

enum PrivilegedOutcome {
    case completed
    case canceled
    case failed(String)
}

enum PrivilegedRunner {
    private typealias AEWP = @convention(c) (
        AuthorizationRef,
        UnsafePointer<CChar>,
        AuthorizationFlags,
        UnsafePointer<UnsafeMutablePointer<CChar>?>,
        UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?
    ) -> OSStatus

    static func run(shellCommand: String, onOutput: @escaping (String) -> Void) -> PrivilegedOutcome {
        var authRef: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &authRef) == errAuthorizationSuccess,
              let auth = authRef else {
            return .failed("Could not create an authorization reference.")
        }
        defer { AuthorizationFree(auth, [.destroyRights]) }

        let rightName = strdup(kAuthorizationRightExecute)!
        defer { free(rightName) }
        var item = AuthorizationItem(name: UnsafePointer(rightName),
                                     valueLength: 0, value: nil, flags: 0)
        let status = withUnsafeMutablePointer(to: &item) { itemPtr -> OSStatus in
            var rights = AuthorizationRights(count: 1, items: itemPtr)
            return AuthorizationCopyRights(auth, &rights, nil,
                                           [.interactionAllowed, .extendRights, .preAuthorize],
                                           nil)
        }
        if status == errAuthorizationCanceled { return .canceled }
        guard status == errAuthorizationSuccess else {
            return .failed("Authorization failed (status \(status)).")
        }

        guard let sym = dlsym(dlopen(nil, RTLD_NOW), "AuthorizationExecuteWithPrivileges") else {
            return .failed("AuthorizationExecuteWithPrivileges is unavailable on this system.")
        }
        let exec = unsafeBitCast(sym, to: AEWP.self)

        var argv: [UnsafeMutablePointer<CChar>?] = [strdup("-c"), strdup(shellCommand), nil]
        defer { argv.compactMap { $0 }.forEach { free($0) } }
        var fp: UnsafeMutablePointer<FILE>?
        let rc = "/bin/sh".withCString { sh in
            exec(auth, sh, [], &argv, &fp)
        }
        guard rc == errAuthorizationSuccess, let pipe = fp else {
            return .failed("Failed to launch the privileged process (status \(rc)).")
        }
        var buf = [CChar](repeating: 0, count: 4096)
        while fgets(&buf, Int32(buf.count), pipe) != nil {
            onOutput(String(cString: buf))
        }
        fclose(pipe)
        return .completed
    }
}

@MainActor
final class Runner: ObservableObject {
    @Published var log = ""
    @Published var running = false
    @Published var canceled = false
    @Published var lastSucceeded: Bool?

    private static let exitSentinel = "__V2D_EXIT__"
    private var raw = ""

    func run(arguments: [String]) {
        guard !running else { return }
        guard let cli = Bundle.main.path(forResource: "ventoy2disk", ofType: nil) else {
            log = "error: ventoy2disk helper missing from app bundle\n"
            lastSucceeded = false
            return
        }
        running = true
        canceled = false
        lastSucceeded = nil
        raw = ""
        log = "$ ventoy2disk " + arguments.joined(separator: " ") + "\n"

        let cmd = ([cli] + arguments).map(shellQuote).joined(separator: " ")
            + " 2>&1; echo \"\(Self.exitSentinel):$?\""
        Task.detached(priority: .userInitiated) {
            let outcome = PrivilegedRunner.run(shellCommand: cmd) { chunk in
                Task { @MainActor in self.append(chunk) }
            }
            await MainActor.run { self.finish(outcome) }
        }
    }

    private func append(_ chunk: String) {
        raw += chunk
        if chunk.contains(Self.exitSentinel) {
            log = log.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.contains(Self.exitSentinel) }
                .joined(separator: "\n")
        } else {
            log += chunk
        }
    }

    private func finish(_ outcome: PrivilegedOutcome) {
        running = false
        switch outcome {
        case .canceled:
            canceled = true
            log += "\nCanceled.\n"
        case .failed(let message):
            lastSucceeded = false
            log += "\n" + message + "\n"
        case .completed:
            if let r = raw.range(of: Self.exitSentinel + ":") {
                let code = Int(raw[r.upperBound...].prefix { $0.isNumber }) ?? -1
                lastSucceeded = (code == 0)
            } else {
                lastSucceeded = false
                log += "\nThe installer exited unexpectedly.\n"
            }
        }
    }
}

private func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
