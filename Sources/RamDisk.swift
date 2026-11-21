import Foundation

/// Dysk w pamięci RAM na pliki otwierane z archiwum: nic nie trafia na dysk, po odmontowaniu dane znikają.
enum RamDisk {
    nonisolated(unsafe) static var dev: String?
    nonisolated(unsafe) static var mount: URL?
    nonisolated(unsafe) static var capacity: Int64 = 0
    nonisolated(unsafe) static var lastError = ""
    static let lock = NSRecursiveLock()
    nonisolated(unsafe) static var extras: [(dev: String, mount: URL)] = []

    @discardableResult
    static func sh(_ exe: String, _ args: [String]) -> (Int32, String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        let o = Pipe(); p.standardOutput = o; p.standardError = o; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "\(error)") }
        let d = (try? o.fileHandleForReading.readToEnd()) ?? Data()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: d, as: UTF8.self))
    }

    static func ensure(bytes: Int64) -> URL? {
        lock.lock(); defer { lock.unlock() }
        let need = max(64 << 20, bytes * 12 / 10 + (16 << 20))
        if let m = mount, capacity >= need { return m }
        eject()
        let (rc, out) = sh("/usr/bin/hdiutil", ["attach", "-nomount", "ram://\((need + 511) / 512)"])
        let d = out.split(whereSeparator: { $0.isWhitespace }).first(where: { $0.hasPrefix("/dev/") }).map(String.init)
        guard rc == 0, let d else { lastError = "attach: " + out; return nil }
        dev = d
        let (r2, o2) = sh("/sbin/newfs_hfs", ["-v", "Archiwum", d])
        guard r2 == 0 else { lastError = "newfs: " + o2; eject(); return nil }
        let mp = FileManager.default.temporaryDirectory.appendingPathComponent("preview-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: mp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let (r3, o3) = sh("/sbin/mount", ["-t", "hfs", "-o", "nobrowse,noowners,nosuid", d, mp.path])
        guard r3 == 0 else { lastError = "mount: " + o3; mount = mp; eject(); return nil }
        mount = mp; capacity = need
        FileManager.default.createFile(atPath: mp.appendingPathComponent(".metadata_never_index").path, contents: Data())
        return mp
    }

    /// A separate RAM disk that stays alive until its window closes (used for archives opened from inside other archives).
    static func ensureNested(bytes: Int64) -> URL? {
        lock.lock(); defer { lock.unlock() }
        let saved = (dev, mount, capacity)
        dev = nil; mount = nil; capacity = 0
        let m = ensure(bytes: bytes)
        let created = (dev, mount)
        (dev, mount, capacity) = saved
        guard let m, let d = created.0 else { return nil }
        extras.append((d, m)); return m
    }
    static func extraMount(containing u: URL) -> URL? { extras.first { u.path.hasPrefix($0.mount.path + "/") }?.mount }
    static func ejectExtra(_ m: URL) {
        lock.lock(); defer { lock.unlock() }
        guard let i = extras.firstIndex(where: { $0.mount == m }) else { return }
        let e = extras.remove(at: i)
        wipeContents(e.mount); sh("/sbin/umount", ["-f", e.mount.path]); try? FileManager.default.removeItem(at: e.mount)
        sh("/usr/bin/hdiutil", ["detach", e.dev, "-force"])
    }
    static func ejectAll() { eject(); for e in extras { ejectExtra(e.mount) } }

    /// Overwrites file contents with zeros before the RAM disk is released.
    static func wipeContents(_ m: URL) {
        guard let en = FileManager.default.enumerator(at: m, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return }
        var budget: Int64 = 4 << 30
        let zeros = Data(count: 1 << 20)
        for case let f as URL in en {
            let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard v?.isRegularFile == true, var left = Int64(v?.fileSize ?? 0) as Int64?, left > 0, budget > 0, let h = try? FileHandle(forWritingTo: f) else { continue }
            budget -= left
            while left > 0 { let n = Int(min(left, 1 << 20)); try? h.write(contentsOf: zeros.prefix(n)); left -= Int64(n) }
            try? h.synchronize(); try? h.close()
        }
    }

    static func eject() {
        lock.lock(); defer { lock.unlock() }
        if let m = mount { wipeContents(m) }
        if let m = mount { sh("/sbin/umount", ["-f", m.path]); try? FileManager.default.removeItem(at: m) }
        if let d = dev { sh("/usr/bin/hdiutil", ["detach", d, "-force"]) }
        mount = nil; dev = nil; capacity = 0
    }

    /// Po awarii: odmontuj pozostałe dyski „preview-” i usuń puste katalogi.
    static func ejectStale() {
        let (_, out) = sh("/sbin/mount", [])
        for line in out.split(separator: "\n") where line.contains("/preview-") {
            let parts = line.components(separatedBy: " on ")
            guard parts.count == 2, let mp = parts[1].components(separatedBy: " (").first else { continue }
            sh("/sbin/umount", ["-f", mp]); sh("/usr/bin/hdiutil", ["detach", parts[0], "-force"])
        }
        let t = FileManager.default.temporaryDirectory
        for n in (try? FileManager.default.contentsOfDirectory(atPath: t.path)) ?? [] where n.hasPrefix("preview-") {
            try? FileManager.default.removeItem(at: t.appendingPathComponent(n))
        }
    }
}
