import SwiftUI
import AppKit
import AVKit
import UniformTypeIdentifiers
import ImageIO
import CryptoKit

// MARK: Silnik: wypakowanie blokujące (przeciąganie do Findera) i SHA

extension Engine {
    static func runSync(_ a: [String], pipeFrom first: [String]? = nil) -> Int32 {
        let p2 = RawProcess(); p2.executableURL = sevenZip; p2.arguments = a
        p2.standardOutput = FileHandle.nullDevice; p2.standardError = FileHandle.nullDevice
        var p1: RawProcess?
        if let first {
            let pr = RawProcess(); pr.executableURL = sevenZip; pr.arguments = first
            let mid = Pipe(); pr.standardOutput = mid; pr.standardError = FileHandle.nullDevice; pr.standardInput = FileHandle.nullDevice
            p2.standardInput = mid
            guard (try? pr.run()) != nil else { return -1 }
            p1 = pr
            guard (try? p2.run()) != nil else { return -1 }
            try? mid.fileHandleForWriting.close(); try? mid.fileHandleForReading.close()
        } else {
            p2.standardInput = FileHandle.nullDevice
            guard (try? p2.run()) != nil else { return -1 }
        }
        p2.waitUntilExit(); if p1?.isRunning == true { p1?.terminate() }
        return p2.terminationStatus
    }

    /// Extracts one entry onto the RAM disk and returns its URL (used when dragging out of the archive).
    static func extractBlocking(archive: URL, wrapped: Bool, password: String?, id: String, size: Int64) -> URL? {
        guard let d = RamDisk.ensure(bytes: max(size, 1 << 20)) else { return nil }
        var args = ["x", "-y", "-aoa", "-spd", "-o" + d.path]
        if let password { args.append("-p" + password) }
        let rc: Int32
        if wrapped { rc = runSync(["x", "-si", "-ttar", "-y", "-aoa", "-spd", "-o" + d.path, id], pipeFrom: ["x", "-so", "-spd", archive.path]) }
        else { rc = runSync(args + [archive.path, id]) }
        return rc == 0 ? d.appendingPathComponent(id) : nil
    }

    static func sha256(of u: URL) -> String? {
        guard let f = try? FileHandle(forReadingFrom: u) else { return nil }
        var h = SHA256()
        while let d = try? f.read(upToCount: 4 << 20), !d.isEmpty { h.update(data: d) }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: Porównanie, wyszukiwanie w treści, ratowanie danych

struct DiffResult { var against: String; var added: [String]; var removed: [String]; var changed: [String]; var same: Int }
struct Hit: Identifiable { let id = UUID(); var path: String; var line: Int; var text: String }

actor ThumbGate {
    static let shared = ThumbGate()
    private var running = 0
    func enter() async { while running >= 3 { try? await Task.sleep(for: .milliseconds(40)) }; running += 1 }
    func leave() { running -= 1 }
}

extension Store {
    static let textExt: Set<String> = ["txt", "md", "json", "xml", "csv", "log", "swift", "py", "js", "ts", "html", "htm", "css", "yml", "yaml", "sh", "c", "h", "cpp", "java", "rs", "go", "tex", "ini", "plist", "sql", "rtf", "conf", "toml", "kt", "rb", "php"]
    static let imageExt: Set<String> = ["jpg", "jpeg", "png", "gif", "heic", "heif", "tif", "tiff", "bmp", "webp"]
    static let videoExt: Set<String> = ["mp4", "mov", "m4v", "mkv", "avi", "webm", "mpg", "mpeg", "3gp", "mts"]

    /// Mapa rozmiarów pokazuje wszystkie pliki (liście) pod bieżącym folderem, a nie tylko jego bezpośrednie wpisy.
    var treemapRows: [Row] {
        let prefix = cwd.isEmpty ? "" : cwd.joined(separator: "/") + "/"
        let q = query.trimmingCharacters(in: .whitespaces)
        return entries.filter { !$0.isDir && $0.size > 0 && $0.path.hasPrefix(prefix) && (q.isEmpty || $0.path.localizedCaseInsensitiveContains(q)) }.map { e in
            Row(id: e.path, name: (e.path as NSString).lastPathComponent, parent: (e.path as NSString).deletingLastPathComponent, isDir: false,
                size: e.size, packed: e.packed, modified: e.modified, encrypted: e.encrypted, crc: e.crc)
        }
    }

    func comparePick() {
        let p = NSOpenPanel(); p.canChooseFiles = true; p.canChooseDirectories = true
        p.message = "Wybierz archiwum lub folder do porównania z „\(url?.lastPathComponent ?? "")”"
        guard p.runModal() == .OK, let other = p.url else { return }
        Task { await compare(with: other) }
    }

    func compare(with other: URL) async {
        let mine = Dictionary(entries.filter { !$0.isDir }.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        var theirs: [String: (Int64, String)] = [:]
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: other.path, isDirectory: &isDir)
        busy = "Porównywanie…"; defer { busy = nil }
        if isDir.boolValue {
            let rp = other.resolvingSymlinksInPath().path; let base = rp.hasSuffix("/") ? rp : rp + "/"
            theirs = await Task.detached { () -> [String: (Int64, String)] in
                var m: [String: (Int64, String)] = [:]
                if let en = FileManager.default.enumerator(at: other, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
                    for case let f as URL in en {
                        let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                        if v?.isRegularFile == true { m[String(f.resolvingSymlinksInPath().path.dropFirst(base.count))] = (Int64(v?.fileSize ?? 0), "") }
                    }
                }
                return m
            }.value
        } else {
            let (list, _, res) = await Engine.list(other, password: nil)
            if list.isEmpty { notice = Engine.needsPassword(res.out) ? "Drugie archiwum jest zaszyfrowane." : "Nie można otworzyć drugiego archiwum."; return }
            theirs = Dictionary(list.filter { !$0.isDir }.map { ($0.path, ($0.size, $0.crc)) }, uniquingKeysWith: { a, _ in a })
        }
        var r = DiffResult(against: other.lastPathComponent, added: [], removed: [], changed: [], same: 0)
        for (p, e) in mine {
            if let t = theirs[p] {
                if t.0 != e.size || (!t.1.isEmpty && !e.crc.isEmpty && t.1 != e.crc) { r.changed.append(p) } else { r.same += 1 }
            } else { r.removed.append(p) }
        }
        r.added = theirs.keys.filter { mine[$0] == nil }
        r.added.sort(); r.removed.sort(); r.changed.sort()
        diff = r; showDiff = true
    }

    func searchContent(_ q: String) async {
        guard let u = url, !q.isEmpty else { return }
        if entries.contains(where: { $0.encrypted }) && password == nil { notice = "Najpierw otwórz archiwum z hasłem."; return }
        let cands = entries.filter { !$0.isDir && $0.size <= 2 << 20 && Store.textExt.contains(($0.path as NSString).pathExtension.lowercased()) }.prefix(3000)
        guard !cands.isEmpty else { searchHits = []; searchNote = "Brak plików tekstowych do przeszukania."; return }
        searching = true; searchHits = []; searchNote = ""
        defer { searching = false }
        let total = cands.reduce(Int64(0)) { $0 + $1.size }
        guard let d = await Task.detached(operation: { RamDisk.ensure(bytes: total) }).value else { searchNote = "Nie udało się utworzyć dysku RAM."; return }
        let paths = cands.map(\.path)
        let pw = password, wr = wrapped
        let rc = await Task.detached { () -> Int32 in
            var a = ["x", "-y", "-aoa", "-spd", "-o" + d.path]; if let pw { a.append("-p" + pw) }
            if wr { return Engine.runSync(["x", "-si", "-ttar", "-y", "-aoa", "-spd", "-o" + d.path] + paths, pipeFrom: ["x", "-so", "-spd", u.path]) }
            return Engine.runSync(a + [u.path] + paths)
        }.value
        if rc > 1 { searchNote = "Błąd rozpakowywania (kod \(rc))."; return }
        let hits = await Task.detached { () -> [Hit] in
            var out: [Hit] = []
            for p in paths {
                guard let data = try? Data(contentsOf: d.appendingPathComponent(p)) else { continue }
                var n = 0
                for (i, line) in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).enumerated() where line.localizedCaseInsensitiveContains(q) {
                    out.append(Hit(path: p, line: i + 1, text: String(line.prefix(160)).trimmingCharacters(in: .whitespaces))); n += 1
                    if n >= 3 || out.count >= 300 { break }
                }
                if out.count >= 300 { break }
            }
            return out
        }.value
        searchHits = hits
        searchNote = hits.isEmpty ? "Brak trafień w \(paths.count) plikach tekstowych." : "\(hits.count) trafień (przeszukano \(paths.count) plików tekstowych)."
    }

    /// Rescues whatever can be read from a damaged archive.
    func recover() {
        let p = NSOpenPanel(); p.canChooseFiles = true; p.canChooseDirectories = false; p.message = "Wybierz uszkodzone archiwum"
        guard p.runModal() == .OK, let a = p.url else { return }
        let d = NSOpenPanel(); d.canChooseFiles = false; d.canChooseDirectories = true; d.canCreateDirectories = true; d.prompt = "Zapisz tutaj"; d.message = "Folder na odzyskane dane"
        guard d.runModal() == .OK, let dest = d.url else { return }
        Task {
            busy = "Odzyskiwanie danych…"; jobStart = Date()
            let target = dest.appendingPathComponent(a.deletingPathExtension().lastPathComponent + "-odzyskane")
            let r = await Engine.run(Engine.sevenZip, ["x", "-y", "-aou", "-spd", "-o" + target.path, a.path])
            busy = nil
            let n = (try? FileManager.default.contentsOfDirectory(atPath: target.path))?.count ?? 0
            let status = r.status == 0 ? "bez błędów" : r.status == 1 ? "z ostrzeżeniami" : "częściowo (są błędy)"
            if n == 0 && r.status != 0 { notice = "Nie udało się nic odzyskać.\n" + String(r.out.suffix(300)); return }
            let errs = r.out.split(separator: "\n").filter { $0.contains("ERROR") || $0.contains("Errors") || $0.contains("Data Error") }.prefix(3).joined(separator: " · ")
            finish(JobResult(icon: "lifepreserver", title: "Odzyskiwanie zakończone", detail: status,
                             lines: [("Odzyskano elementów", "\(n)"), ("Czas", elapsed)] + (errs.isEmpty ? [] : [("Uwagi", String(errs.prefix(90)))]), reveal: target))
        }
    }

    func signArchive() {
        guard let u = url else { return }
        Task {
            busy = "Podpisywanie…"
            let out = await Task.detached { Signer.sign(u) }.value
            busy = nil
            if let out { finish(JobResult(icon: "signature", title: "Archiwum podpisane", detail: out.lastPathComponent, lines: [("Klucz", Signer.myFingerprint), ("Algorytm", "Ed25519 + SHA-256")], reveal: out)) }
            else { notice = "Nie udało się podpisać archiwum." }
        }
    }
    func verifySignature() {
        guard let u = url else { return }
        Task {
            busy = "Weryfikacja podpisu…"
            let v = await Task.detached { Signer.verify(u) }.value
            busy = nil
            switch v {
            case .ok(let mine, let fp, let date):
                finish(JobResult(icon: "checkmark.seal.fill", title: mine ? "Podpis prawidłowy (Twój klucz)" : "Podpis prawidłowy (obcy klucz)",
                                 detail: mine ? "Archiwum nie zostało zmienione od podpisania" : "Sprawdź, czy ufasz właścicielowi tego klucza",
                                 lines: [("Odcisk klucza", fp), ("Podpisano", String(date.prefix(19)).replacingOccurrences(of: "T", with: " "))]))
            case .changed: notice = "UWAGA: archiwum zostało zmienione po podpisaniu (suma SHA-256 się nie zgadza)."
            case .badSignature: notice = "UWAGA: podpis jest nieprawidłowy lub sfałszowany."
            case .missing: notice = "Brak pliku \(u.lastPathComponent).sig obok archiwum."
            case .unreadable: notice = "Nie można odczytać pliku podpisu."
            }
        }
    }

    func writeSHAFile() {
        guard let u = url else { return }
        Task {
            busy = "Liczenie SHA-256…"
            let h = await Task.detached { Engine.sha256(of: u) }.value
            busy = nil
            guard let h else { notice = "Nie udało się odczytać pliku."; return }
            sha = h
            let out = u.appendingPathExtension("sha256")
            try? "\(h)  \(u.lastPathComponent)\n".write(to: out, atomically: true, encoding: .utf8)
            finish(JobResult(icon: "number.square.fill", title: "Zapisano sumę kontrolną", detail: out.lastPathComponent, lines: [("SHA-256", String(h.prefix(24)) + "…")], reveal: out))
        }
    }
    func verifySHAFile() {
        guard let u = url else { return }
        let side = u.appendingPathExtension("sha256")
        guard let txt = try? String(contentsOf: side, encoding: .utf8), let want = txt.split(separator: " ").first.map(String.init) else {
            notice = "Brak pliku \(side.lastPathComponent) obok archiwum."; return
        }
        Task {
            busy = "Weryfikacja SHA-256…"
            let h = await Task.detached { Engine.sha256(of: u) }.value
            busy = nil
            if h == want.lowercased() { finish(JobResult(icon: "checkmark.seal.fill", title: "Suma się zgadza", detail: "Archiwum nie zostało zmienione", lines: [("SHA-256", String(want.prefix(24)) + "…")])) }
            else { notice = "UWAGA: suma SHA-256 NIE zgadza się z plikiem .sha256 — archiwum zostało zmienione lub uszkodzone." }
        }
    }

    // Miniatury w pamięci
    func thumb(_ r: Row) async -> NSImage? {
        if let t = thumbs[r.id] { return t }
        guard let u = url, Store.imageExt.contains(r.ext), r.size < 12 << 20, !(entries.contains { $0.encrypted } && password == nil) else { return nil }
        await ThumbGate.shared.enter()
        let pw = password, wr = wrapped, id = r.id
        let data: Data = await Task.detached {
            if wr { return await Engine.runData(["x", "-so", "-spd", u.path], ["x", "-si", "-ttar", "-so", "-spd", id], password: nil).data }
            return await Engine.runData(nil, ["x", "-so", "-spd"] + (pw != nil ? ["-p"] : []) + [u.path, id], password: pw).data
        }.value
        await ThumbGate.shared.leave()
        guard !data.isEmpty, let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 320, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        thumbs[id] = img
        return img
    }

    // Przeciąganie z archiwum
    func dragProvider(_ r: Row) -> NSItemProvider {
        let p = NSItemProvider()
        p.suggestedName = r.name
        guard let u = url else { return p }
        let pw = password, wr = wrapped, id = r.id, size = r.size
        let type = r.isDir ? UTType.folder : (UTType(filenameExtension: r.ext) ?? .data)
        p.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            DispatchQueue.global().async {
                let out = Engine.extractBlocking(archive: u, wrapped: wr, password: pw, id: id, size: size)
                completion(out, false, out == nil ? NSError(domain: "Archiwum", code: 1) : nil)
            }
            return nil
        }
        return p
    }
}

// MARK: Widoki

struct ThumbGrid: View {
    var rows: [Row]; var sel: Set<String>
    var onTap: (Row) -> Void; var onOpen: (Row) -> Void
    @ObservedObject var s = Store.shared
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 170), spacing: 10)], spacing: 10) {
                ForEach(rows) { r in
                    VStack(spacing: 5) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.08))
                            if let t = s.thumbs[r.id] { Image(nsImage: t).resizable().scaledToFill().frame(width: 130, height: 100).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)) }
                            else { Image(systemName: r.isDir ? "folder.fill" : Store.videoExt.contains(r.ext) ? "film.fill" : Store.imageExt.contains(r.ext) ? "photo" : "doc.fill").font(.system(size: 30)).foregroundStyle(.white.opacity(0.6)) }
                        }
                        .frame(width: 130, height: 100)
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(sel.contains(r.id) ? 0.95 : 0.15), lineWidth: sel.contains(r.id) ? 3 : 1))
                        Text(r.name).font(.system(size: 11)).lineLimit(1).truncationMode(.middle).frame(width: 130)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { onOpen(r) }
                    .onTapGesture { onTap(r) }
                    .task { _ = await s.thumb(r) }
                    .onDrag { s.dragProvider(r) }
                }
            }.padding(.horizontal, 20).padding(.vertical, 8)
        }
    }
}

struct DiffSheet: View {
    @ObservedObject var s = Store.shared
    func group(_ title: String, _ items: [String], _ color: Color, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("\(title) (\(items.count))", systemImage: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(color)
            if items.isEmpty { Text("—").foregroundStyle(.white.opacity(0.4)).font(.caption) }
            ForEach(items.prefix(150), id: \.self) { Text($0).font(.system(size: 11)).lineLimit(1).truncationMode(.middle) }
            if items.count > 150 { Text("… i \(items.count - 150) więcej").font(.caption).foregroundStyle(.white.opacity(0.5)) }
        }.card()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                GlyphBadge(symbol: "arrow.left.arrow.right", colors: Palette.blue, size: 48)
                VStack(alignment: .leading) {
                    Text("Porównanie").font(.title2.bold())
                    Text("\(s.url?.lastPathComponent ?? "") ↔ \(s.diff?.against ?? "")").foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
            }
            if let d = s.diff {
                Text("\(d.same) identycznych · \(d.changed.count) zmienionych · \(d.removed.count) tylko tutaj · \(d.added.count) tylko w drugim").font(.caption).foregroundStyle(.white.opacity(0.7))
                ScrollView { VStack(spacing: 8) {
                    group("Zmienione", d.changed, .yellow, "pencil")
                    group("Tylko w tym archiwum", d.removed, Palette.orange[0], "minus.circle")
                    group("Tylko w drugim", d.added, Palette.green[0], "plus.circle")
                } }.frame(height: 320)
            }
            HStack { Spacer(); Button("Zamknij") { s.showDiff = false }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 560).foregroundStyle(.white).environment(\.colorScheme, .dark)
        .presentationBackground { GlassBackground(radius: 0) }
    }
}

struct ContentSearchSheet: View {
    @ObservedObject var s = Store.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                GlyphBadge(symbol: "text.magnifyingglass", colors: Palette.green, size: 48)
                VStack(alignment: .leading) {
                    Text("Szukaj w treści plików").font(.title2.bold())
                    Text("Pliki tekstowe są rozpakowywane tylko na dysk RAM.").font(.caption).foregroundStyle(.white.opacity(0.6))
                }
            }
            HStack {
                TextField("Szukana fraza", text: $s.searchQuery).textFieldStyle(.roundedBorder).onSubmit { Task { await s.searchContent(s.searchQuery) } }
                Button("Szukaj") { Task { await s.searchContent(s.searchQuery) } }.buttonStyle(.glassProminent).disabled(s.searching || s.searchQuery.isEmpty)
                if s.searching { ProgressView().controlSize(.small) }
            }
            Text(s.searchNote).font(.caption).foregroundStyle(.white.opacity(0.6))
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(s.searchHits) { h in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(h.path):\(h.line)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(red: 0.65, green: 0.82, blue: 1)).lineLimit(1).truncationMode(.head)
                            Text(h.text).font(.system(size: 12, design: .monospaced)).lineLimit(2)
                        }.card().onTapGesture { Task { await s.perform(.preview(h.path)) } }
                    }
                }
            }.frame(height: 260)
            HStack { Spacer(); Button("Zamknij") { s.showSearch = false }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 580).foregroundStyle(.white).environment(\.colorScheme, .dark)
        .presentationBackground { GlassBackground(tint: Palette.green[0], radius: 0) }
    }
}

struct WarningsPopover: View {
    var warnings: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Uwagi dotyczące bezpieczeństwa", systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(.orange)
            ForEach(warnings, id: \.self) { Text("• " + $0).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true) }
        }.padding(16).frame(width: 360).environment(\.colorScheme, .dark)
    }
}

struct HelpSheet: View {
    @ObservedObject var s = Store.shared
    let rows: [(String, String)] = [
        ("Przeciągnij archiwum", "otwiera je; kilka archiwów naraz → wypakowanie wsadowe"), ("Przeciągnij pliki", "tworzy nowe archiwum"),
        ("Dwuklik / Enter", "otwiera plik (dysk RAM) lub wchodzi do folderu"), ("Spacja", "podgląd w pamięci (obraz, PDF, tekst, wideo)"),
        ("⌘A · ⌘/⇧ + klik", "zaznaczanie wielu plików"), ("⌘F", "szukaj w archiwum"), ("⌘I", "panel informacji"),
        ("⌘E", "wypakuj"), ("⇧⌘T", "testuj"), ("⇧⌘L", "zablokuj (zapomnij hasło)"), ("Przeciąganie wiersza", "wypakowuje plik do Findera lub innej aplikacji"),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Archiwum — skróty i wskazówki").font(.title2.bold())
            ForEach(rows, id: \.0) { r in HStack(alignment: .top) { Text(r.0).font(.system(size: 12, weight: .semibold)).frame(width: 160, alignment: .leading); Text(r.1).font(.system(size: 12)).foregroundStyle(.white.opacity(0.75)) } }
            Divider().overlay(.white.opacity(0.2))
            Text("Pliki otwierane z archiwum trafiają na dysk w pamięci RAM, który jest zerowany i odmontowywany po użyciu. Hasła nie są zapisywane, chyba że zaznaczysz zapamiętanie w Pęku kluczy (odblokowanie przez Touch ID).")
                .font(.caption).foregroundStyle(.white.opacity(0.6))
            HStack { Spacer(); Button("Zamknij") { s.showHelp = false }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 560).foregroundStyle(.white).environment(\.colorScheme, .dark)
        .presentationBackground { GlassBackground(radius: 0) }
    }
}

struct VideoPlayerBox: NSViewRepresentable {
    var url: URL
    func makeNSView(context: Context) -> AVPlayerView { let v = AVPlayerView(); v.player = AVPlayer(url: url); v.controlsStyle = .floating; return v }
    func updateNSView(_ v: AVPlayerView, context: Context) {}
    static func dismantleNSView(_ v: AVPlayerView, coordinator: ()) { v.player?.pause() }
}
