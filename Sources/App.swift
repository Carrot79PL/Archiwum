import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PDFKit
import CryptoKit

struct Row: Identifiable, Hashable {
    var id: String        // pełna ścieżka
    var name: String
    var parent = ""
    var isDir: Bool
    var size: Int64
    var packed: Int64
    var modified: String
    var created = ""
    var encrypted: Bool
    var crc = ""
    var method = ""
    var attrs = ""
    var count = 0
    var ext: String { (name as NSString).pathExtension.lowercased() }
    var kind: String { isDir ? "Folder" : (ext.isEmpty ? "Plik" : ext.uppercased()) }
}

enum Job { case none, pack, unpack, test, add
    var title: String { switch self { case .none: ""; case .pack: "Pakowanie"; case .unpack: "Rozpakowywanie"; case .test: "Sprawdzanie"; case .add: "Dodawanie" } }
}
enum ViewMode { case list, treemap, thumbs }
struct JobResult: Identifiable {
    let id = UUID()
    var icon = "checkmark"
    var title: String
    var detail: String
    var lines: [(String, String)] = []
    var reveal: URL?
}

enum SortKey: String, CaseIterable, Identifiable {
    case name = "Nazwa", size = "Rozmiar", packed = "Po spakowaniu", date = "Data", type = "Typ"
    var id: String { rawValue }
}
enum Overwrite: String, CaseIterable, Identifiable {
    case rename = "Zmień nazwę nowych plików", overwrite = "Nadpisz istniejące", skip = "Pomiń istniejące"
    var id: String { rawValue }
    var flag: String { self == .rename ? "-aou" : self == .overwrite ? "-aoa" : "-aos" }
}

enum Pending { case extract(URL, [String]), test, open([String]), preview(String) }

struct PreviewItem: Identifiable { let id = UUID(); var name: String; var data: Data }

@MainActor final class Store: ObservableObject {
    static let shared = Store()
    @Published var url: URL?
    @Published var entries: [Entry] = []
    @Published var cwd: [String] = []
    @Published var password: String?
    @Published var progress: Double? {
        didSet { NSApplication.shared.dockTile.badgeLabel = progress.map { "\(Int($0 * 100))%" } }
    }
    @Published var currentFile = ""
    @Published var job: Job = .none
    @Published var result: JobResult?
    @Published var viewMode: ViewMode = .list
    @Published var showDuplicates = false
    @Published var warnings: [String] = []
    @Published var thumbs: [String: NSImage] = [:]
    @Published var diff: DiffResult?
    @Published var showDiff = false
    @Published var showSearch = false
    @Published var searchQuery = ""
    @Published var searchHits: [Hit] = []
    @Published var searchNote = ""
    @Published var searching = false
    @Published var showHelp = false
    @Published var rememberPW = false
    @Published var videoURL: URL?
    @Published var estimates: [Estimate] = []
    @Published var estimating = false
    @Published var showConvert = false
    @Published var convertOpts = CreateOptions()
    @Published var batchURLs: [URL] = []
    @Published var showBatch = false
    @Published var batchStatus: [URL: String] = [:]
    @Published var batchRunning = false
    @Published var batchDest: URL?
    static let archiveExt: Set<String> = ["7z", "zip", "rar", "tar", "gz", "tgz", "bz2", "xz", "iso", "cab", "wim", "lzh", "zst", "cbz", "cbr", "cb7"]
    @Published var sha: String?
    @Published var shaBusy = false
    @Published var busy: String?
    @Published var notice: String?
    @Published var pending: Pending?
    @Published var passwordError = false
    @Published var previewItem: PreviewItem?
    @Published var info = ArchiveInfo()
    @Published var query = ""
    @Published var sortKey: SortKey = .name
    @Published var ascending = true
    @Published var showInspector = true
    @Published var showExtract = false
    @Published var extractSel: [String] = []
    @Published var extractDest: URL?
    @Published var subfolder = true
    @Published var overwrite: Overwrite = .rename
    @Published var revealAfter = true
    @Published var deleteIDs: [String] = []
    @Published var jobStart: Date?
    @Published var showCreate = false
    @Published var createOpts = CreateOptions()
    @Published var createConfirm = ""
    var proc: RawProcess?
    private init() { Engine.onFile = { f in Task { @MainActor in Store.shared.currentFile = f } } }

    func finish(_ r: JobResult) {
        result = r
        if UserDefaults.standard.object(forKey: "sound") as? Bool ?? true { NSSound(named: "Glass")?.play() }
        Notifier.post(r.title, r.detail)
        let id = r.id
        Task { try? await Task.sleep(for: .seconds(9)); if Store.shared.result?.id == id { Store.shared.result = nil } }
    }
    /// Czy wybrane elementy (albo całe archiwum, gdy `sel` puste) zawierają zaszyfrowane pliki — tylko wtedy pytamy o hasło.
    func needsPassword(for sel: [String]) -> Bool {
        if headerLocked { return true }
        return entries.contains { e in e.encrypted && (sel.isEmpty || sel.contains { e.path == $0 || e.path.hasPrefix($0 + "/") }) }
    }
    func filesUnder(_ sel: [String]) -> [Entry] {
        entries.filter { e in !e.isDir && (sel.isEmpty || sel.contains { e.path == $0 || e.path.hasPrefix($0 + "/") }) }
    }
    var elapsed: String {
        let t = Int(Date().timeIntervalSince(jobStart ?? Date()))
        return t < 60 ? "\(max(t, 1)) s" : "\(t / 60) min \(t % 60) s"
    }
    var duplicates: [[Entry]] {
        var g: [String: [Entry]] = [:]
        for e in entries where !e.isDir && e.size > 0 && !e.crc.isEmpty { g["\(e.crc)-\(e.size)", default: []].append(e) }
        return g.values.filter { $0.count > 1 }.sorted { $0[0].size * Int64($0.count) > $1[0].size * Int64($1.count) }
    }
    func runEstimate() {
        guard !createOpts.files.isEmpty, !estimating else { return }
        estimating = true; estimates = []
        let f = createOpts.files
        Task { let e = await Engine.estimate(files: f); estimates = e; estimating = false }
    }

    func exportList() {
        guard url != nil else { return }
        let sp = NSSavePanel(); sp.nameFieldStringValue = baseName + "-zawartosc.csv"
        guard sp.runModal() == .OK, let out = sp.url else { return }
        func q(_ x: String) -> String { "\"" + x.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var csv = "Sciezka;Rozmiar;Spakowany;Zmodyfikowany;CRC;Zaszyfrowany;Typ\n"
        for e in entries { csv += [q(e.path), "\(e.size)", "\(e.packed)", q(e.modified), e.crc, e.encrypted ? "tak" : "nie", e.isDir ? "folder" : "plik"].joined(separator: ";") + "\n" }
        do { try csv.write(to: out, atomically: true, encoding: .utf8); finish(JobResult(icon: "tablecells", title: "Lista wyeksportowana", detail: out.lastPathComponent, lines: [("Pozycji", "\(entries.count)")], reveal: out)) }
        catch { notice = "Błąd zapisu: \(error.localizedDescription)" }
    }

    func convert() async {
        guard let u = url else { return }
        if entries.contains(where: { $0.encrypted }) && password == nil { notice = "Najpierw otwórz archiwum z hasłem."; return }
        let total = filesUnder([]).reduce(Int64(0)) { $0 + $1.size }
        let sp = NSSavePanel(); sp.nameFieldStringValue = baseName + "." + convertOpts.format.rawValue; sp.directoryURL = u.deletingLastPathComponent()
        guard sp.runModal() == .OK, let out = sp.url else { return }
        showConvert = false
        busy = "Przygotowanie dysku RAM…"
        let d = await Task.detached { RamDisk.ensure(bytes: total) }.value
        func fail(_ m: String) { busy = nil; progress = nil; job = .none; RamDisk.eject(); notice = m }
        guard let d else { fail("Nie udało się utworzyć dysku RAM na \(fmt(total)).\n" + RamDisk.lastError); return }
        busy = "Rozpakowywanie…"; progress = 0; jobStart = Date(); job = .unpack; currentFile = ""
        var args = ["x", "-y", "-bsp1", "-spd", "-o" + d.path]; if password != nil { args.append("-p") }; args.append(u.path)
        let r1: RunResult
        if wrapped { r1 = await Engine.runPipe(["x", "-so", "-spd", u.path], ["x", "-si", "-ttar", "-y", "-spd", "-o" + d.path], onStart: { p in Task { @MainActor in Store.shared.proc = p } }) }
        else { r1 = await Engine.run(Engine.sevenZip, args, password: password, onStart: { p in Task { @MainActor in Store.shared.proc = p } }, progress: { v in Task { @MainActor in Store.shared.progress = v / 2 } }) }
        guard r1.status == 0 else { fail(r1.status == 255 ? "Anulowano." : "Błąd rozpakowywania:\n" + String(r1.out.suffix(300))); return }
        let kids = (try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []
        var o = convertOpts; o.files = kids; o.trashOriginals = false
        busy = "Pakowanie…"; progress = 0.5; job = .pack; currentFile = ""
        let r2 = await Engine.create(o, output: out, onStart: { p in Task { @MainActor in Store.shared.proc = p } },
                                     progress: { v in Task { @MainActor in Store.shared.progress = 0.5 + v / 2 } })
        RamDisk.eject()
        busy = nil; progress = nil; job = .none; convertOpts = CreateOptions()
        if r2.status == 0 {
            let outBytes = Int64((try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            let before = Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            finish(JobResult(icon: "arrow.triangle.2.circlepath", title: "Skonwertowano", detail: "\(u.lastPathComponent) → \(out.lastPathComponent)",
                             lines: [("Przed", fmt(before)), ("Po", fmt(outBytes)), ("Czas", elapsed), ("Pośrednio", "dysk RAM (bez zapisu)")], reveal: out))
        } else { notice = "Błąd pakowania:\n" + String(r2.out.suffix(300)) }
    }

    func pickBatchDest() {
        let p = NSOpenPanel(); p.canChooseFiles = false; p.canChooseDirectories = true; p.canCreateDirectories = true; p.prompt = "Wybierz"
        if p.runModal() == .OK { batchDest = p.url }
    }
    func runBatch() async {
        guard let dest = batchDest else { return }
        batchRunning = true; jobStart = Date(); batchStatus = [:]
        var ok = 0
        for u in batchURLs {
            batchStatus[u] = "…"
            var n = u.deletingPathExtension().lastPathComponent; if n.hasSuffix(".tar") { n = String(n.dropLast(4)) }
            let target = subfolder ? dest.appendingPathComponent(n) : dest
            let r = await Engine.run(Engine.sevenZip, ["x", "-y", overwrite.flag, "-spd", "-o" + target.path, u.path])
            batchStatus[u] = r.status == 0 ? "ok" : (Engine.needsPassword(r.out) ? "hasło" : "błąd")
            if r.status == 0 { ok += 1 }
        }
        batchRunning = false
        finish(JobResult(icon: "square.stack.3d.down.right.fill", title: "Wypakowano wsadowo", detail: "\(ok) z \(batchURLs.count) archiwów",
                         lines: [("Czas", elapsed)], reveal: dest))
    }

    func computeSHA() {
        guard let u = url, !shaBusy else { return }
        shaBusy = true; sha = nil
        Task {
            let h = await Task.detached(priority: .userInitiated) { () -> String? in
                guard let f = try? FileHandle(forReadingFrom: u) else { return nil }
                var hasher = SHA256()
                while let d = try? f.read(upToCount: 4 << 20), !d.isEmpty { hasher.update(data: d) }
                return hasher.finalize().map { String(format: "%02x", $0) }.joined()
            }.value
            sha = h; shaBusy = false
        }
    }
    var wrapped = false
    private var lastUse = Date()
    private var headerLocked = false
    private var timer: Timer?

    var canModify: Bool { !wrapped && ["7z", "zip"].contains(info.type.lowercased()) }
    var isEncryptedArchive: Bool { password != nil || entries.contains { $0.encrypted } }
    var baseName: String {
        guard let u = url else { return "Archiwum" }
        var n = u.deletingPathExtension().lastPathComponent
        if n.hasSuffix(".tar") { n = String(n.dropLast(4)) }
        return n
    }

    var rows: [Row] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var list: [Row]
        if !q.isEmpty {
            list = entries.filter { !$0.isDir && $0.path.localizedCaseInsensitiveContains(q) }.map { e in
                Row(id: e.path, name: (e.path as NSString).lastPathComponent, parent: (e.path as NSString).deletingLastPathComponent,
                    isDir: false, size: e.size, packed: e.packed, modified: e.modified, created: e.created, encrypted: e.encrypted,
                    crc: e.crc, method: e.method, attrs: e.attrs)
            }
        } else {
            let prefix = cwd.isEmpty ? "" : cwd.joined(separator: "/") + "/"
            var dict: [String: Row] = [:]
            for e in entries where e.path.hasPrefix(prefix) && e.path != String(prefix.dropLast()) {
                let rest = e.path.dropFirst(prefix.count)
                let parts = rest.split(separator: "/", omittingEmptySubsequences: true)
                guard let first = parts.first else { continue }
                let name = String(first), id = prefix + name
                let isDir = parts.count > 1 || e.isDir
                var r = dict[name] ?? Row(id: id, name: name, isDir: isDir, size: 0, packed: 0, modified: "", encrypted: false)
                if parts.count == 1 { r.modified = e.modified; r.created = e.created; r.attrs = e.attrs; if !e.isDir { r.crc = e.crc; r.method = e.method } }
                if !e.isDir { r.size += e.size; r.packed += e.packed; r.count += 1 }
                r.encrypted = r.encrypted || e.encrypted
                r.isDir = r.isDir || isDir
                dict[name] = r
            }
            list = Array(dict.values)
        }
        let flat = !q.isEmpty
        return list.sorted { a, b in
            if !flat && a.isDir != b.isDir { return a.isDir }
            var c: ComparisonResult
            switch sortKey {
            case .name: c = a.name.localizedStandardCompare(b.name)
            case .size: c = a.size == b.size ? .orderedSame : (a.size < b.size ? .orderedAscending : .orderedDescending)
            case .packed: c = a.packed == b.packed ? .orderedSame : (a.packed < b.packed ? .orderedAscending : .orderedDescending)
            case .date: c = a.modified.compare(b.modified)
            case .type: c = a.kind.compare(b.kind)
            }
            if c == .orderedSame { c = a.name.localizedStandardCompare(b.name) }
            return ascending ? c == .orderedAscending : c == .orderedDescending
        }
    }

    func openPanel() {
        let p = NSOpenPanel(); p.canChooseFiles = true; p.canChooseDirectories = false
        p.message = "Wybierz archiwum"
        if p.runModal() == .OK, let u = p.url { Task { await open(u) } }
    }

    func open(_ u: URL, password pw: String? = nil) async {
        busy = "Otwieranie…"; defer { busy = nil }
        var (list, ainfo, res) = await Engine.list(u, password: pw)
        wrapped = false
        wipe()
        if list.count == 1, list[0].path.hasSuffix(".tar"), !u.lastPathComponent.hasSuffix(".tar") {
            let l2 = await Engine.listWrapped(u)
            if !l2.isEmpty { list = l2; res = RunResult(out: "", status: 0); wrapped = true }
        }
        if list.isEmpty && res.status != 0 {
            if Engine.needsPassword(res.out) {
                if pw == nil, KeychainPW.exists(u.path), await Biometric.authenticate("Odblokuj archiwum „\(u.lastPathComponent)”"), let saved = KeychainPW.load(u.path) { await open(u, password: saved); return }
                password = nil; passwordError = pw != nil
                url = u; entries = []; cwd = []
                pendingOpen = u
                return
            }
            notice = "Nie można otworzyć pliku jako archiwum.\n" + String(res.out.suffix(300)); return
        }
        url = u; entries = list; info = wrapped ? ArchiveInfo(type: "tar") : ainfo; cwd = []; password = pw; notice = nil; query = ""; sha = nil; thumbs = [:]
        warnings = Security.analyze(entries: list, archiveSize: Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
        if let pw, rememberPW { KeychainPW.save(u.path, pw) }; rememberPW = false
        headerLocked = pw != nil; lastUse = Date()
    }
    @Published var pendingOpen: URL?

    func submitPassword(_ pw: String) async {
        if let u = pendingOpen { pendingOpen = nil; await open(u, password: pw); return }
        password = pw
        if let p = pending { pending = nil; await perform(p) }
    }

    func choose(for sel: [String]) {
        extractSel = sel
        if extractDest == nil { extractDest = url?.deletingLastPathComponent() }
        showExtract = true
    }
    func pickDestination() {
        let p = NSOpenPanel(); p.canChooseFiles = false; p.canChooseDirectories = true; p.canCreateDirectories = true
        p.prompt = "Wybierz"; p.message = "Wybierz folder docelowy"
        if p.runModal() == .OK, let d = p.url { extractDest = d }
    }
    func runExtract() {
        guard let d = extractDest else { return }
        showExtract = false
        let target = subfolder ? d.appendingPathComponent(baseName) : d
        Task { await perform(.extract(target, extractSel)) }
    }

    func addFiles() {
        let p = NSOpenPanel(); p.canChooseFiles = true; p.canChooseDirectories = true; p.allowsMultipleSelection = true
        p.prompt = "Dodaj"; p.message = "Wybierz pliki do dodania do archiwum"
        if p.runModal() == .OK { let urls = p.urls; Task { await addFiles(urls) } }
    }
    func addFiles(_ urls: [URL]) async {
        guard let u = url, !urls.isEmpty, canModify else { return }
        if entries.contains(where: { $0.encrypted }) && password == nil { notice = "Archiwum jest zaszyfrowane — otwórz je z hasłem, aby je zmienić."; return }
        busy = "Dodawanie…"; progress = 0; jobStart = Date(); job = .add; currentFile = ""
        let res = await Engine.add(to: u, files: urls, password: password,
                                   onStart: { p in Task { @MainActor in Store.shared.proc = p } },
                                   progress: { v in Task { @MainActor in Store.shared.progress = v } })
        busy = nil; progress = nil; proc = nil; job = .none
        if res.status == 0 { let t = elapsed; await open(u, password: password); finish(JobResult(icon: "doc.badge.plus", title: "Dodano do archiwum", detail: "\(urls.count) elem.", lines: [("Czas", t)])) }
        else { notice = "Błąd:\n" + String(res.out.suffix(400)) }
    }
    func deleteEntries(_ ids: [String]) async {
        guard let u = url, !ids.isEmpty, canModify else { return }
        if entries.contains(where: { $0.encrypted }) && password == nil { notice = "Archiwum jest zaszyfrowane — otwórz je z hasłem, aby je zmienić."; return }
        busy = "Usuwanie…"
        let res = await Engine.delete(from: u, paths: ids, password: password)
        busy = nil
        if res.status == 0 { await open(u, password: password); finish(JobResult(icon: "trash", title: "Usunięto z archiwum", detail: "\(ids.count) elem.")) }
        else { notice = "Błąd:\n" + String(res.out.suffix(400)) }
    }

    static let mediaExt: Set<String> = ["jpg","jpeg","png","gif","heic","heif","tif","tiff","bmp","webp","dng","cr2","cr3","nef","arw","raf","orf","rw2","mp4","mov","m4v","mkv","avi","webm","mpg","mpeg","3gp","mts"]
    var migawka: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "local.przegladarka.zdjec") }
    /// Zdjęcia i filmy: Migawka sama rozpakowuje archiwum na swój dysk RAM (obsługuje hasło), nic nie trafia na dysk.
    func openInMigawka() {
        guard let u = url, let app = migawka else { notice = "Nie znaleziono aplikacji Migawka."; return }
        lastUse = Date()
        NSWorkspace.shared.open([u], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
    nonisolated static func wipePreviews() { RamDisk.eject(); RamDisk.ejectStale() }
    func wipe() { RamDisk.eject() }

    /// Podgląd wyłącznie w pamięci — nic nie trafia na dysk.
    func preview(_ id: String) async {
        guard let u = url else { return }
        lastUse = Date()
        if needsPassword(for: [id]) && password == nil {
            if KeychainPW.exists(u.path), await Biometric.authenticate("Odblokuj archiwum"), let saved = KeychainPW.load(u.path) { password = saved }
            else { pending = .preview(id); passwordError = false; return }
        }
        if Store.videoExt.contains((id as NSString).pathExtension.lowercased()) {
            let sz = entries.first(where: { $0.path == id })?.size ?? 0
            busy = "Przygotowanie wideo…"
            let pw = password, wr = wrapped
            let out = await Task.detached { Engine.extractBlocking(archive: u, wrapped: wr, password: pw, id: id, size: sz) }.value
            busy = nil
            if let out { videoURL = out } else { notice = "Nie udało się przygotować wideo na dysku RAM." }
            return
        }
        if let e = entries.first(where: { $0.path == id }), e.size > 256 << 20 { notice = "Plik jest za duży na podgląd w pamięci (>256 MB). Użyj „Wypakuj do…”."; return }
        busy = "Wczytywanie…"
        var args = ["x", "-so", "-spd"]; if password != nil { args.append("-p") }
        let r: (data: Data, status: Int32, err: String)
        if wrapped { r = await Engine.runData(["x", "-so", "-spd", u.path], ["x", "-si", "-ttar", "-so", "-spd", id], password: nil) }
        else { r = await Engine.runData(nil, args + [u.path, id], password: password) }
        busy = nil
        if r.status == 0 { previewItem = PreviewItem(name: (id as NSString).lastPathComponent, data: r.data) }
        else if Engine.needsPassword(r.err) { password = nil; pending = .preview(id); passwordError = true }
        else { notice = "Błąd:\n" + String(r.err.suffix(300)) }
    }

    func perform(_ orig: Pending) async {
        if case .preview(let id) = orig { await preview(id); return }
        var a = orig; var openIDs: [String] = []
        if case .open(let ids) = orig {
            var files = ids.filter { id in !(entries.first(where: { $0.path == id })?.isDir ?? false) }
            guard !files.isEmpty else { return }
            if migawka != nil {
                let media = files.filter { Store.mediaExt.contains(($0 as NSString).pathExtension.lowercased()) }
                if !media.isEmpty { openInMigawka(); files.removeAll { media.contains($0) } }
                if files.isEmpty { return }
            }
            let total = entries.filter { files.contains($0.path) }.reduce(Int64(0)) { $0 + $1.size }
            busy = "Tworzenie dysku RAM…"
            let d = await Task.detached { RamDisk.ensure(bytes: total) }.value
            busy = nil
            guard let d else {
                if files.count == 1 { await preview(files[0]) } else { notice = "Nie udało się utworzyć dysku RAM.\n" + RamDisk.lastError }
                return
            }
            openIDs = files; a = .extract(d, files)
        }
        guard let u = url else { return }
        lastUse = Date()
        let selForCheck: [String]
        switch orig { case .extract(_, let sl): selForCheck = sl; case .open(let ids): selForCheck = ids; default: selForCheck = [] }
        if needsPassword(for: selForCheck) && password == nil {
            if KeychainPW.exists(u.path), await Biometric.authenticate("Odblokuj archiwum"), let saved = KeychainPW.load(u.path) { password = saved }
            else { pending = orig; passwordError = false; return }
        }
        var args: [String]; let label: String
        switch a {
        case .extract(let d, let sel):
            args = ["x", "-y", overwrite.flag, "-bsp1", "-spd", "-o" + d.path]; label = "Wypakowywanie…"
            if password != nil { args.append("-p") }
            args.append(u.path); args += sel
        case .test:
            args = ["t", "-bsp1"]; label = "Sprawdzanie…"
            if password != nil { args.append("-p") }
            args.append(u.path)
        case .open, .preview: return
        }
        busy = label; progress = 0; jobStart = Date(); currentFile = ""
        if case .test = a { job = .test } else { job = .unpack }
        let selForStats: [String]; if case .extract(_, let sl) = a { selForStats = sl } else { selForStats = [] }
        let statFiles = filesUnder(selForStats)
        if case .extract(let dd, _) = a, openIDs.isEmpty, let free = Security.freeSpace(at: dd) {
            let need = statFiles.reduce(Int64(0)) { $0 + $1.size }
            if free < need { busy = nil; progress = nil; job = .none; notice = "Za mało miejsca w miejscu docelowym: potrzeba \(fmt(need)), wolne \(fmt(free))."; return }
        }
        let res: RunResult
        if wrapped, case .extract(let d, let sel) = a {
            res = await Engine.runPipe(["x", "-so", "-spd", u.path],
                                       ["x", "-si", "-ttar", "-y", overwrite.flag, "-spd", "-o" + d.path] + sel,
                                       onStart: { p in Task { @MainActor in Store.shared.proc = p } })
        } else {
            res = await Engine.run(Engine.sevenZip, args, password: password,
                                   onStart: { p in Task { @MainActor in Store.shared.proc = p } },
                                   progress: { v in Task { @MainActor in Store.shared.progress = v } })
        }
        busy = nil; progress = nil; proc = nil; job = .none
        if res.status == 0 {
            switch a {
            case .extract(let d, let sl):
                if let q = Security.quarantine(of: u) { Security.propagateQuarantine(q, to: d, names: sl.isEmpty ? entries.map(\.path) : sl) }
                if !openIDs.isEmpty { for id in openIDs { NSWorkspace.shared.open(d.appendingPathComponent(id)) } }
                else {
                    let total = statFiles.reduce(Int64(0)) { $0 + $1.size }
                    finish(JobResult(icon: "arrow.down.doc.fill", title: "Wypakowano", detail: d.lastPathComponent,
                                     lines: [("Plików", "\(statFiles.count)"), ("Rozmiar", fmt(total)), ("Czas", elapsed), ("Folder", d.path)], reveal: d))
                    if revealAfter { NSWorkspace.shared.activateFileViewerSelecting([d]) }
                }
            case .open, .preview: break
            case .test:
                let all = filesUnder([])
                finish(JobResult(icon: "checkmark.shield.fill", title: "Archiwum jest poprawne", detail: "Wszystkie sumy kontrolne zgadzają się",
                                 lines: [("Plików", "\(all.count)"), ("Rozmiar", fmt(all.reduce(Int64(0)) { $0 + $1.size })), ("Czas", elapsed)]))
            }
        } else if Engine.needsPassword(res.out) && (needsPassword(for: selForCheck) || password != nil) {
            password = nil; pending = orig; passwordError = true
        } else if res.status == 255 { notice = "Anulowano." }
        else {
            let errs = res.out.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).filter { $0.contains("ERROR") || $0.contains("Error") || $0.contains("Can't") || $0.contains("Missing") || $0.contains("Unsupported") || $0.contains("Cannot") }
            notice = "Błąd wypakowywania (kod \(res.status)):\n" + (errs.isEmpty ? String(res.out.suffix(500)) : errs.prefix(6).joined(separator: "\n"))
        }
    }

    func startLockTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            Task { @MainActor in Store.shared.lockIfIdle() }
        }
    }
    func lockIfIdle() {
        let mins = UserDefaults.standard.object(forKey: "autoLock") as? Int ?? 5
        guard mins > 0, busy == nil, password != nil, Date().timeIntervalSince(lastUse) > Double(mins * 60) else { return }
        lock()
    }
    /// Zapomina hasło; jeśli nazwy plików były zaszyfrowane, zamyka też listę.
    func lock() {
        password = nil; wipe()
        if headerLocked { url = nil; entries = []; cwd = []; headerLocked = false }
        notice = nil
    }
    func cancel() { proc?.terminate() }

    func create() async {
        let o = createOpts
        guard !o.files.isEmpty else { return }
        let sp = NSSavePanel()
        let base = o.files.count == 1 ? o.files[0].deletingPathExtension().lastPathComponent : "Archiwum"
        sp.nameFieldStringValue = base + "." + o.format.rawValue
        sp.directoryURL = o.files[0].deletingLastPathComponent()
        guard sp.runModal() == .OK, let out = sp.url else { return }
        await runCreate(o, out)
    }

    /// Szybkie archiwizowanie z Findera: bez okien dialogowych, 7z obok oryginału.
    func quickArchive(_ urls: [URL]) async {
        guard let first = urls.first else { return }
        let parent = first.deletingLastPathComponent()
        let base = urls.count == 1 ? first.lastPathComponent : "Archiwum"
        var out = parent.appendingPathComponent(base + ".7z"); var n = 2
        while FileManager.default.fileExists(atPath: out.path) { out = parent.appendingPathComponent("\(base) \(n).7z"); n += 1 }
        var o = CreateOptions(); o.files = urls
        await runCreate(o, out)
    }

    func extractHere(_ urls: [URL]) {
        guard let first = urls.first else { return }
        batchURLs = urls; batchStatus = [:]; batchDest = first.deletingLastPathComponent(); subfolder = true; overwrite = .rename
        Task { await runBatch() }
    }

    func runCreate(_ o: CreateOptions, _ out: URL) async {
        showCreate = false
        let inBytes = await Task.detached { () -> Int64 in
            var t: Int64 = 0
            for u in o.files {
                if let en = FileManager.default.enumerator(at: u, includingPropertiesForKeys: [.fileSizeKey]) {
                    for case let f as URL in en { t += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
                }
                t += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            return t
        }.value
        busy = "Tworzenie archiwum…"; progress = 0; jobStart = Date(); job = .pack; currentFile = ""
        let res = await Engine.create(o, output: out,
                                      onStart: { p in Task { @MainActor in Store.shared.proc = p } },
                                      progress: { v in Task { @MainActor in Store.shared.progress = v } })
        busy = nil; progress = nil; proc = nil; job = .none; createOpts = CreateOptions(); createConfirm = ""
        var verifyLine: String? = nil
        if res.status == 0, o.verify, o.format.supportsPassword, o.volumeMB == 0 {
            busy = "Weryfikacja…"
            let v = await Engine.run(Engine.sevenZip, ["t"] + (o.password.isEmpty ? [] : ["-p"]) + [out.path], password: o.password.isEmpty ? nil : o.password)
            busy = nil
            verifyLine = v.status == 0 ? "OK ✓" : "BŁĄD!"
        }
        if res.status == 0 {
            let outBytes = Int64((try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            var lines = [("Oryginał", fmt(inBytes)), ("Archiwum", fmt(outBytes))]
            if inBytes > 0 { lines.append(("Oszczędność", "\(max(0, 100 - Int(Double(outBytes) / Double(inBytes) * 100)))%")) }
            lines.append(("Czas", elapsed))
            if let v = verifyLine { lines.append(("Weryfikacja", v)) }
            if o.trashOriginals && verifyLine != "BŁĄD!" { NSWorkspace.shared.recycle(o.files) { _, _ in }; lines.append(("Oryginały", "przeniesione do Kosza")) }
            finish(JobResult(icon: "archivebox.fill", title: "Archiwum utworzone", detail: out.lastPathComponent, lines: lines, reveal: out))
            NSWorkspace.shared.activateFileViewerSelecting([out])
        }
        else { notice = "Błąd:\n" + String(res.out.suffix(400)) }
    }

    func handleDrop(_ urls: [URL]) {
        if urls.count > 1, urls.allSatisfy({ Store.archiveExt.contains($0.pathExtension.lowercased()) }) {
            batchURLs = urls; batchStatus = [:]; if batchDest == nil { batchDest = urls[0].deletingLastPathComponent() }; showBatch = true; return
        }
        if urls.count == 1, !urls[0].hasDirectoryPath { Task { await open(urls[0]) } }
        else { createOpts.files = urls; showCreate = true }
    }
}

@_silgen_name("ptrace") func ptrace_(_ r: Int32, _ pid: Int32, _ a: UnsafeMutableRawPointer?, _ d: Int32) -> Int32

@main struct ArchiwumApp: App {
    init() {
        if CommandLine.arguments.contains("--selftest-ram") {
            let m = RamDisk.ensure(bytes: 1 << 20)
            if let m { try? "ok".write(to: m.appendingPathComponent("t.txt"), atomically: false, encoding: .utf8)
                print("RAM OK", m.path, (try? String(contentsOf: m.appendingPathComponent("t.txt"), encoding: .utf8)) ?? "read-fail") }
            else { print("RAM FAIL", RamDisk.lastError) }
            RamDisk.eject(); exit(0)
        }
        signal(SIGPIPE, SIG_IGN)
        if let i = CommandLine.arguments.firstIndex(of: "--selftest"), i + 1 < CommandLine.arguments.count {
            let d = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            Task { @MainActor in await runSelfTest(d) }
        }
        NSApplication.shared.servicesProvider = ServicesProvider.shared
        var rl = rlimit(rlim_cur: 0, rlim_max: 0); setrlimit(RLIMIT_CORE, &rl)   // brak zrzutów pamięci
        _ = ptrace_(31, 0, nil, 0)                                                // PT_DENY_ATTACH
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
        RamDisk.ejectStale()
        Store.shared.startLockTimer()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in Store.wipePreviews() }
        NotificationCenter.default.addObserver(forName: NSApplication.willResignActiveNotification, object: nil, queue: .main) { _ in }
    }
    var body: some Scene {
        Window("Archiwum", id: "main") {
            ContentView().onOpenURL { u in Task { await Store.shared.open(u) } }
        }
        .restorationBehavior(.disabled)
        .defaultSize(width: 1120, height: 720)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Nowe archiwum…") { Store.shared.createOpts = CreateOptions(); Store.shared.showCreate = true }.keyboardShortcut("n")
                Button("Otwórz archiwum…") { Store.shared.openPanel() }.keyboardShortcut("o")
            }
            CommandMenu("Archiwum") {
                Button("Porównaj z…") { Store.shared.comparePick() }
                Button("Szukaj w treści plików…") { Store.shared.showSearch = true }.keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Ratuj dane z uszkodzonego archiwum…") { Store.shared.recover() }
                Button("Zapisz sumę SHA-256 (.sha256)") { Store.shared.writeSHAFile() }
                Button("Zweryfikuj z plikiem .sha256") { Store.shared.verifySHAFile() }
                Button("Podpisz cyfrowo (Ed25519)") { Store.shared.signArchive() }
                Button("Zweryfikuj podpis cyfrowy") { Store.shared.verifySignature() }
                Divider()
                Button("Testuj archiwum") { Task { await Store.shared.perform(.test) } }.keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Konwertuj do innego formatu…") { Store.shared.convertOpts = CreateOptions(); Store.shared.showConvert = true }
                Button("Dodaj pliki do archiwum…") { Store.shared.addFiles() }
                Button("Szukaj duplikatów") { Store.shared.showDuplicates = true }
                Button("Oblicz SHA-256 archiwum") { Store.shared.computeSHA() }
                Divider()
                Button("Eksportuj listę zawartości (CSV)…") { Store.shared.exportList() }
                Button("Zablokuj (zapomnij hasło)") { Store.shared.lock() }.keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }
        Settings { SettingsView() }
        .commands { CommandGroup(replacing: .help) { Button("Pomoc i skróty") { Store.shared.showHelp = true } } }
    }
}


struct PDFBox: NSViewRepresentable {
    var data: Data
    func makeNSView(context: Context) -> PDFView { let v = PDFView(); v.document = PDFDocument(data: data); v.autoScales = true; return v }
    func updateNSView(_ v: PDFView, context: Context) {}
}

struct PreviewView: View {
    var item: PreviewItem
    @ObservedObject var s = Store.shared
    var ext: String { (item.name as NSString).pathExtension.lowercased() }
    var text: String? {
        guard item.data.count < 4 << 20, !item.data.contains(0) else { return nil }
        return String(data: item.data, encoding: .utf8)
    }
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "eye.fill")
                Text(item.name).font(.headline).lineLimit(1)
                Text(fmt(Int64(item.data.count))).foregroundStyle(.white.opacity(0.6))
                Spacer()
                Button("Zamknij") { s.previewItem = nil }.keyboardShortcut(.cancelAction)
            }
            Group {
                if let img = NSImage(data: item.data), ext != "pdf" {
                    Image(nsImage: img).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 14))
                } else if ext == "pdf", PDFDocument(data: item.data) != nil {
                    PDFBox(data: item.data).clipShape(RoundedRectangle(cornerRadius: 14))
                } else if let t = text {
                    ScrollView { Text(t).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12) }
                        .background(RoundedRectangle(cornerRadius: 14).fill(.black.opacity(0.25)))
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "eye.slash").font(.largeTitle)
                        Text("Tego typu pliku nie da się podejrzeć bez zapisu na dysk.").multilineTextAlignment(.center)
                        Text("Użyj „Wypakuj do…” albo „Otwórz” (dysk RAM, domyślna aplikacja systemu).").font(.caption).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Text("Podgląd jest tylko w pamięci — po zamknięciu dane znikają, nic nie trafia na dysk.").font(.caption).foregroundStyle(.white.opacity(0.55))
        }
        .padding(20).frame(minWidth: 560, minHeight: 420).foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .presentationBackground { GlassBackground(radius: 0) }
    }
}
