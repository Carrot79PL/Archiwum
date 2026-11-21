import Foundation

struct Entry: Hashable {
    var path: String
    var size: Int64
    var packed: Int64
    var modified: String
    var isDir: Bool
    var encrypted: Bool
    var crc = ""
    var method = ""
    var attrs = ""
    var created = ""
}

struct ArchiveInfo {
    var type = "", method = "", solid = "", blocks = "", comment = ""
    var physical: Int64 = 0, headers: Int64 = 0
}

struct RunResult { var out: String; var status: Int32 }

final class Buf: @unchecked Sendable {
    private var s = ""; private let l = NSLock()
    func add(_ x: String) { l.lock(); s += x; l.unlock() }
    var text: String { l.lock(); defer { l.unlock() }; return s }
}

enum Engine {
    static var sevenZip: URL {
        Bundle.main.url(forResource: "7zz", withExtension: nil) ?? URL(fileURLWithPath: "/opt/homebrew/bin/7zz")
    }
    static let bsdtar = URL(fileURLWithPath: "/usr/bin/bsdtar")

    nonisolated(unsafe) static var onFile: (@Sendable (String) -> Void)?
    static let fileRx = try! NSRegularExpression(pattern: #"^\s*\d+%(?:\s+\d+)?\s+[-+U.]\s+(.+?)\s*$"#)
    static func lastFile(_ s: String) -> String? {
        for line in s.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).reversed() {
            let l = String(line)
            if let m = fileRx.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)), let r = Range(m.range(at: 1), in: l) { return String(l[r]) }
        }
        return nil
    }
    static func lastPercent(_ s: String) -> Double? {
        guard let r = s.range(of: #"(\d{1,3})%"#, options: [.regularExpression, .backwards]) else { return nil }
        return Double(s[r].dropLast()).map { $0 / 100 }
    }

    static func run(_ exe: URL, _ args: [String], password: String? = nil, cwd: URL? = nil,
                    onStart: (@Sendable (RawProcess) -> Void)? = nil,
                    progress: (@Sendable (Double) -> Void)? = nil) async -> RunResult {
        await withCheckedContinuation { cont in
            let p = RawProcess()
            p.executableURL = exe
            let args = args.contains("-bsp1") && !args.contains("-bb1") ? [args[0], "-bb1"] + args.dropFirst() : args
            p.arguments = password.map { pw in args.map { $0 == "-p" ? "-p" + pw : $0 } } ?? args
            if let cwd { p.currentDirectoryURL = cwd }
            p.environment = ProcessInfo.processInfo.environment.merging(["COPYFILE_DISABLE": "1"]) { $1 }
            let inp = Pipe(), outp = Pipe()
            p.standardInput = inp; p.standardOutput = outp; p.standardError = outp
            let buf = Buf()
            outp.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData; if d.isEmpty { return }
                let s = String(decoding: d, as: UTF8.self)
                buf.add(s)
                if let progress, let v = lastPercent(s) { progress(v) }
                if let f = lastFile(s) { onFile?(f) }
            }
            p.terminationHandler = { pr in
                outp.fileHandleForReading.readabilityHandler = nil
                let rest = outp.fileHandleForReading.readDataToEndOfFile()
                buf.add(String(decoding: rest, as: UTF8.self))
                cont.resume(returning: RunResult(out: buf.text, status: pr.terminationStatus))
            }
            do { try p.run() } catch {
                cont.resume(returning: RunResult(out: "Nie można uruchomić silnika: \(error.localizedDescription)", status: -1)); return
            }
            onStart?(p)
            try? inp.fileHandleForWriting.close()
        }
    }

    static func list(_ url: URL, password: String?) async -> (entries: [Entry], info: ArchiveInfo, res: RunResult) {
        var args = ["l", "-slt", "-sccUTF-8", "-spd"]
        if password != nil { args.append("-p") }
        args.append(url.path)
        let res = await run(sevenZip, args, password: password)
        var header = "", body = res.out
        if let r = res.out.range(of: "\n----------\n") { header = String(res.out[..<r.lowerBound]); body = String(res.out[r.upperBound...]) }
        var info = ArchiveInfo()
        for line in header.split(separator: "\n") {
            guard let r = line.range(of: " = ") else { continue }
            let k = line[..<r.lowerBound], v = String(line[r.upperBound...])
            switch k {
            case "Type": info.type = v
            case "Method": info.method = v
            case "Solid": info.solid = v
            case "Blocks": info.blocks = v
            case "Comment": info.comment = v
            case "Physical Size": info.physical = Int64(v) ?? 0
            case "Headers Size": info.headers = Int64(v) ?? 0
            default: break
            }
        }
        return (parse(body, name: url.deletingPathExtension().lastPathComponent), info, res)
    }

    static func parse(_ out: String, name: String) -> [Entry] {
        var entries: [Entry] = []
        var cur: [String: String] = [:]
        func flush() {
            if let p = cur["Path"] ?? (cur["Size"] != nil ? name : nil) {
                let attr = cur["Attributes"] ?? ""
                entries.append(Entry(path: p, size: Int64(cur["Size"] ?? "") ?? 0, packed: Int64(cur["Packed Size"] ?? "") ?? 0,
                                     modified: String((cur["Modified"] ?? "").prefix(16)),
                                     isDir: cur["Folder"] == "+" || attr.hasPrefix("D") || attr.contains(" D"),
                                     encrypted: cur["Encrypted"] == "+",
                                     crc: cur["CRC"] ?? "", method: cur["Method"] ?? "", attrs: attr,
                                     created: String((cur["Created"] ?? "").prefix(16))))
            }
            cur = [:]
        }
        for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty { flush(); continue }
            if let r = line.range(of: " = ") { cur[String(line[..<r.lowerBound])] = String(line[r.upperBound...]) }
        }
        flush()
        return entries
    }

    /// Dodaje pliki do istniejącego archiwum (7z/zip).
    static func add(to archive: URL, files: [URL], password: String?, onStart: (@Sendable (RawProcess) -> Void)?, progress: (@Sendable (Double) -> Void)?) async -> RunResult {
        let parent = files[0].deletingLastPathComponent()
        let same = files.allSatisfy { $0.deletingLastPathComponent() == parent }
        var a = ["a", "-bsp1", "-spd"]; if password != nil { a.append("-p") }
        a.append(archive.path); a += files.map { same ? $0.lastPathComponent : $0.path }
        return await run(sevenZip, a, password: password, cwd: parent, onStart: onStart, progress: progress)
    }

    /// Usuwa wpisy z archiwum.
    static func delete(from archive: URL, paths: [String], password: String?) async -> RunResult {
        var a = ["d", "-spd"]; if password != nil { a.append("-p") }
        a.append(archive.path); a += paths
        return await run(sevenZip, a, password: password)
    }

    /// Strumieniowo (bez plików tymczasowych): zdekompresuj .gz/.bz2/.xz i pokaż zawartość wewnętrznego TAR-a.
    static func listWrapped(_ url: URL) async -> [Entry] {
        let r = await runPipe(["x", "-so", "-spd", url.path], ["l", "-slt", "-ba", "-ttar", "-si", "-sccUTF-8"])
        return parse(r.out, name: "")
    }

    static func runPipe(_ a1: [String], _ a2: [String], onStart: (@Sendable (RawProcess) -> Void)? = nil) async -> RunResult {
        await withCheckedContinuation { cont in
            let p1 = RawProcess(), p2 = RawProcess(); let mid = Pipe(), outp = Pipe()
            p1.executableURL = sevenZip; p1.arguments = a1
            p1.standardInput = FileHandle.nullDevice; p1.standardOutput = mid; p1.standardError = FileHandle.nullDevice
            p2.executableURL = sevenZip; p2.arguments = a2
            p2.standardInput = mid; p2.standardOutput = outp; p2.standardError = outp
            let buf = Buf()
            outp.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData; if !d.isEmpty { buf.add(String(decoding: d, as: UTF8.self)) }
            }
            p2.terminationHandler = { pr in
                outp.fileHandleForReading.readabilityHandler = nil
                buf.add(String(decoding: outp.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
                if p1.isRunning { p1.terminate() }
                cont.resume(returning: RunResult(out: buf.text, status: pr.terminationStatus))
            }
            do { try p1.run(); try p2.run() } catch { cont.resume(returning: RunResult(out: "\(error)", status: -1)); return }
            try? mid.fileHandleForWriting.close(); try? mid.fileHandleForReading.close()
            onStart?(p2)
        }
    }

    /// Wynik prosto do pamięci (bez zapisu na dysk): dane z stdout ostatniego procesu.
    static func runData(_ first: [String]?, _ args: [String], password: String?) async -> (data: Data, status: Int32, err: String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p1 = RawProcess(), p2 = RawProcess(); let mid = Pipe(), outp = Pipe(), errp = Pipe()
                p2.executableURL = sevenZip
                p2.arguments = password.map { pw in args.map { $0 == "-p" ? "-p" + pw : $0 } } ?? args
                p2.standardOutput = outp; p2.standardError = errp; p2.standardInput = FileHandle.nullDevice
                if let first {
                    p1.executableURL = sevenZip; p1.arguments = first
                    p1.standardInput = FileHandle.nullDevice; p1.standardOutput = mid; p1.standardError = FileHandle.nullDevice
                    p2.standardInput = mid
                }
                let eb = Buf()
                errp.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData; if !d.isEmpty { eb.add(String(decoding: d, as: UTF8.self)) }
                }
                do { if first != nil { try p1.run() }; try p2.run() } catch { cont.resume(returning: (Data(), -1, "\(error)")); return }
                if first != nil { try? mid.fileHandleForWriting.close(); try? mid.fileHandleForReading.close() }
                let data = (try? outp.fileHandleForReading.readToEnd()) ?? Data()
                p2.waitUntilExit()
                errp.fileHandleForReading.readabilityHandler = nil
                if first != nil, p1.isRunning { p1.terminate() }
                cont.resume(returning: (data, p2.terminationStatus, eb.text))
            }
        }
    }

    static func needsPassword(_ out: String) -> Bool {
        let o = out.lowercased()
        return o.contains("wrong password") || o.contains("enter password") || o.contains("encrypted")
    }
}

enum Format: String, CaseIterable, Identifiable {
    case sevenZ = "7z", zip = "zip", tarGz = "tar.gz", tarBz2 = "tar.bz2", tarXz = "tar.xz", tar = "tar"
    var id: String { rawValue }
    var supportsPassword: Bool { self == .sevenZ || self == .zip }
    var label: String {
        switch self {
        case .sevenZ: "7z (najlepsza kompresja)"
        case .zip: "ZIP (kompatybilny)"
        case .tarGz: "TAR.GZ"
        case .tarBz2: "TAR.BZ2"
        case .tarXz: "TAR.XZ"
        case .tar: "TAR (bez kompresji)"
        }
    }
}

enum Level: Int, CaseIterable, Identifiable {
    case store = 0, fast = 1, normal = 5, maximum = 7, ultra = 9, extreme = 10
    var id: Int { rawValue }
    var label: String {
        switch self { case .store: "Bez kompresji"; case .fast: "Szybka"; case .normal: "Normalna"; case .maximum: "Maksymalna"; case .ultra: "Ultra"; case .extreme: "Ekstremalny (ogromny słownik)" }
    }
    var mx: Int { self == .extreme ? 9 : rawValue
    }
}

struct CreateOptions {
    var files: [URL] = []
    var format: Format = .sevenZ
    var level: Level = .normal
    var password = ""
    var encryptNames = true
    var method: Method = .lzma2
    var solid = true
    var volumeMB = 0
    var dictMB = 256
    var excludeSystem = true
    var verify = true
    var trashOriginals = false
}

enum Method: String, CaseIterable, Identifiable {
    case lzma2 = "LZMA2", ppmd = "PPMd", bzip2 = "BZip2", deflate = "Deflate"
    var id: String { rawValue }
    var label: String {
        switch self { case .lzma2: "LZMA2 (domyślna, najlepszy stosunek)"; case .ppmd: "PPMd (tekst)"; case .bzip2: "BZip2"; case .deflate: "Deflate (szybka, zgodna)" }
    }
}

extension Engine {
    static func create(_ o: CreateOptions, output: URL,
                       onStart: (@Sendable (RawProcess) -> Void)?, progress: (@Sendable (Double) -> Void)?) async -> RunResult {
        try? FileManager.default.removeItem(at: output)
        let parent = o.files[0].deletingLastPathComponent()
        let same = o.files.allSatisfy { $0.deletingLastPathComponent() == parent }
        let names = o.files.map { same ? $0.lastPathComponent : $0.path }
        switch o.format {
        case .sevenZ, .zip:
            var a = ["a", "-bsp1", "-spd", "-mx=\(o.level.mx)", o.format == .sevenZ ? "-t7z" : "-tzip"]
            if o.level == .extreme { a += o.format == .sevenZ ? ["-md=\(o.dictMB)m", "-mfb=273", "-mmt=on"] : ["-mpass=15", "-mfb=258"] }
            if o.excludeSystem { a += ["-xr!.DS_Store", "-xr!._*", "-xr!__MACOSX"] }
            if o.level != .store {
                if o.format == .sevenZ { a.append("-m0=\(o.method.rawValue)"); a.append("-ms=\(o.solid ? "on" : "off")") }
                else { a.append("-mm=\(o.method == .lzma2 ? "Deflate" : o.method.rawValue)") }
            }
            if o.volumeMB > 0 { a.append("-v\(o.volumeMB)m") }
            let pw = !o.password.isEmpty
            if pw {
                a.append("-p")
                if o.format == .sevenZ { if o.encryptNames { a.append("-mhe=on") } } else { a.append("-mem=AES256") }
            }
            a.append(output.path); a += names
            return await run(sevenZip, a, password: pw ? o.password : nil, cwd: parent, onStart: onStart, progress: progress)
        default:
            let flag = ["tar.gz": "-czf", "tar.bz2": "-cjf", "tar.xz": "-cJf", "tar": "-cf"][o.format.rawValue]!
            let ex = o.excludeSystem ? ["--exclude", ".DS_Store", "--exclude", "._*", "--exclude", "__MACOSX"] : []
            return await run(bsdtar, [flag, output.path] + ex + ["-C", parent.path] + names.map { same ? $0 : $0 }, cwd: parent, onStart: onStart, progress: nil)
        }
    }
}


struct Estimate: Identifiable { let id = UUID(); var label: String; var bytes: Int64; var ratio: Double }

extension Engine {
    /// Pipes `input` through 7zz and returns the number of output bytes (nothing is written to disk).
    static func compressedSize(_ args: [String], input: Data) async -> Int64? {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = RawProcess(); p.executableURL = sevenZip; p.arguments = args
                let inp = Pipe(), outp = Pipe()
                p.standardInput = inp; p.standardOutput = outp; p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: nil); return }
                DispatchQueue.global().async { try? inp.fileHandleForWriting.write(contentsOf: input); try? inp.fileHandleForWriting.close() }
                var n: Int64 = 0
                while let d = try? outp.fileHandleForReading.read(upToCount: 1 << 20), !d.isEmpty { n += Int64(d.count) }
                p.waitUntilExit()
                cont.resume(returning: p.terminationStatus == 0 ? n : nil)
            }
        }
    }

    /// Quick estimate: compresses a sample (up to ~16 MB) of the input with several methods and extrapolates.
    static func estimate(files: [URL]) async -> [Estimate] {
        let (sample, total) = await Task.detached { () -> (Data, Int64) in
            var list: [(URL, Int64)] = []
            for u in files {
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
                if isDir.boolValue, let en = FileManager.default.enumerator(at: u, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
                    for case let f as URL in en {
                        let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                        if v?.isRegularFile == true { list.append((f, Int64(v?.fileSize ?? 0))) }
                        if list.count > 5000 { break }
                    }
                } else { list.append((u, Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))) }
            }
            let total = list.reduce(Int64(0)) { $0 + $1.1 }
            let picks = list.enumerated().filter { $0.offset % max(1, list.count / 12) == 0 }.prefix(12).map(\.element)
            var data = Data()
            for (u, sz) in picks {
                if let h = try? FileHandle(forReadingFrom: u), let d = try? h.read(upToCount: min(Int(sz), 1_400_000)) { data.append(d) }
            }
            return (data, total)
        }.value
        guard sample.count > 0, total > 0 else { return [] }
        var out: [Estimate] = []
        for (label, args) in [("Szybka (LZMA2, -1)", ["a", "-txz", "-si", "-so", "-mx=1", "dummy"]), ("Normalna (LZMA2, -5)", ["a", "-txz", "-si", "-so", "-mx=5", "dummy"]),
                              ("Ultra (LZMA2, -9)", ["a", "-txz", "-si", "-so", "-mx=9", "dummy"]), ("ZIP (Deflate)", ["a", "-tgzip", "-si", "-so", "-mx=6", "dummy"])] {
            if let n = await compressedSize(args, input: sample) {
                let r = min(Double(n) / Double(sample.count), 1.0)
                out.append(Estimate(label: label, bytes: Int64(r * Double(total)), ratio: r))
            }
        }
        return out
    }
}
