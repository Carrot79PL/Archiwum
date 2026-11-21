import Foundation

/// Minimal `Process` replacement based on posix_spawn.
///
/// Foundation's `Process` converts every argument to the file-system representation, which on macOS
/// **decomposes Unicode (NFD)**. Archives created elsewhere store names (and passwords) composed (NFC), so
/// names such as „Zdjęcia” or passwords containing „ą/ę/ł” would no longer match. This class passes the
/// exact UTF-8 bytes of every argument to the child process.
final class RawProcess: @unchecked Sendable {
    var executableURL: URL?
    var arguments: [String]?
    var currentDirectoryURL: URL?
    var environment: [String: String]?
    var standardInput: Any?
    var standardOutput: Any?
    var standardError: Any?
    var terminationHandler: (@Sendable (RawProcess) -> Void)?

    private(set) var terminationStatus: Int32 = 0
    private var pid: pid_t = 0
    private var running = false
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    private func fd(_ x: Any?, input: Bool) -> Int32? {
        if let p = x as? Pipe { return input ? p.fileHandleForReading.fileDescriptor : p.fileHandleForWriting.fileDescriptor }
        if let h = x as? FileHandle { return h.fileDescriptor }
        return nil
    }

    func run() throws {
        guard let exe = executableURL else { throw NSError(domain: "RawProcess", code: 1) }
        var fa: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        for (target, obj, input) in [(Int32(0), standardInput, true), (1, standardOutput, false), (2, standardError, false)] {
            if let s = fd(obj, input: input) { posix_spawn_file_actions_adddup2(&fa, s, target) }
        }
        if let cwd = currentDirectoryURL { posix_spawn_file_actions_addchdir_np(&fa, cwd.path) }
        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(0x4000))   // POSIX_SPAWN_CLOEXEC_DEFAULT: the child gets only 0/1/2

        let args = [exe.path] + (arguments ?? [])
        var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }; argv.append(nil)
        var env = ProcessInfo.processInfo.environment
        if let e = environment { env = e }
        var envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") }; envp.append(nil)
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }

        var p: pid_t = 0
        let rc = posix_spawn(&p, exe.path, &fa, &attr, argv, envp)
        guard rc == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(rc)) }
        lock.lock(); pid = p; running = true; lock.unlock()
        // The child owns its ends now; close ours so readers get EOF when the child exits.
        for (obj, input) in [(standardInput, true), (standardOutput, false), (standardError, false)] {
            if let pipe = obj as? Pipe { try? (input ? pipe.fileHandleForReading : pipe.fileHandleForWriting).close() }
        }
        DispatchQueue.global().async { [self] in
            var st: Int32 = 0
            while waitpid(p, &st, 0) < 0 && errno == EINTR {}
            lock.lock()
            terminationStatus = (st & 0x7f) == 0 ? (st >> 8) & 0xff : st & 0x7f
            running = false
            lock.unlock()
            done.signal()
            terminationHandler?(self)
        }
    }

    func waitUntilExit() { done.wait(); done.signal() }
    func terminate() { lock.lock(); let p = pid, r = running; lock.unlock(); if r { kill(p, SIGTERM) } }
}
