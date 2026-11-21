import Foundation
import AppKit

/// Headless integration test: `Archiwum.app/Contents/MacOS/Archiwum --selftest <dir>`
@MainActor func runSelfTest(_ dir: URL) async {
    var fails = 0
    func check(_ name: String, _ ok: Bool, _ extra: String = "") { print(ok ? "PASS" : "FAIL", name, extra); if !ok { fails += 1 } }
    let fm = FileManager.default
    try? fm.removeItem(at: dir); try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let src = dir.appendingPathComponent("src")
    try? fm.createDirectory(at: src.appendingPathComponent("docs/deep"), withIntermediateDirectories: true)
    try? "Klucz: kluczowa fraza w dokumencie\nDruga linia".write(to: src.appendingPathComponent("docs/a.txt"), atomically: true, encoding: .utf8)
    try? "Klucz: kluczowa fraza w dokumencie\nDruga linia".write(to: src.appendingPathComponent("docs/deep/copy.txt"), atomically: true, encoding: .utf8)
    try? String(repeating: "lorem ipsum ", count: 2000).write(to: src.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)
    try? fm.createSymbolicLink(at: src.appendingPathComponent("link"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    try? rep.representation(using: .png, properties: [:])!.write(to: src.appendingPathComponent("pic.png"))

    // 1. Tworzenie we wszystkich formatach
    for f in Format.allCases {
        for pw in (f.supportsPassword ? ["", "haslo"] : [""]) {
            var o = CreateOptions(); o.files = [src]; o.format = f; o.password = pw
            let out = dir.appendingPathComponent("t\(pw.isEmpty ? "" : "_pw").\(f.rawValue)")
            let r = await Engine.create(o, output: out, onStart: nil, progress: nil)
            check("create \(f.rawValue)\(pw.isEmpty ? "" : " +hasło")", r.status == 0 && fm.fileExists(atPath: out.path))
        }
    }
    let s = Store.shared; s.revealAfter = false
    // 2. Otwieranie, nawigacja, wyszukiwanie
    await s.open(dir.appendingPathComponent("t_pw.7z"))
    check("zaszyfrowane 7z wymaga hasła", s.pendingOpen != nil)
    s.pendingOpen = nil
    await s.open(dir.appendingPathComponent("t_pw.7z"), password: "haslo")
    check("open 7z z hasłem", !s.entries.isEmpty, "\(s.entries.count) wpisów, typ \(s.info.type)")
    check("widok główny", s.rows.contains { $0.name == "src" })
    s.cwd = ["src"]; check("nawigacja do folderu", s.rows.contains { $0.name == "docs" } && s.rows.contains { $0.name == "pic.png" })
    s.cwd = []; s.query = "copy"; check("wyszukiwanie", s.rows.count == 1); s.query = ""
    check("duplikaty", s.duplicates.count >= 1, "\(s.duplicates.count) grup")
    let lk = dir.appendingPathComponent("lk.zip")
    do { let p = Process(); p.executableURL = Engine.sevenZip; p.arguments = ["a", "-snl", "-spd", lk.path, "src/link", "src/big.txt"]; p.currentDirectoryURL = dir
         p.standardOutput = FileHandle.nullDevice; try? p.run(); p.waitUntilExit() }
    let keep = (s.url, s.entries); await s.open(lk)
    check("ostrzeżenie o dowiązaniu", s.warnings.contains { $0.contains("dowiąza") }, s.warnings.joined(separator: "|"))
    _ = keep
    await s.open(dir.appendingPathComponent("t_pw.7z"), password: "haslo")
    // 3. Podgląd, miniatury, przeciąganie (RAM)
    await s.perform(.preview("src/docs/a.txt"))
    check("podgląd w pamięci", s.previewItem?.data.count ?? 0 > 10); s.previewItem = nil
    let row = Row(id: "src/pic.png", name: "pic.png", isDir: false, size: 1000, packed: 1000, modified: "", encrypted: false)
    check("miniatura", await s.thumb(row) != nil)
    let ex = Engine.extractBlocking(archive: dir.appendingPathComponent("t_pw.7z"), wrapped: false, password: "haslo", id: "src/docs/a.txt", size: 100)
    check("wypakowanie na dysk RAM", ex != nil && (try? String(contentsOf: ex!, encoding: .utf8))?.contains("kluczowa") == true, ex?.path ?? "")
    check("RAM nie jest indeksowany", ex.map { fm.fileExists(atPath: $0.deletingLastPathComponent().path + "/.metadata_never_index") } ?? false || RamDisk.mount.map { fm.fileExists(atPath: $0.appendingPathComponent(".metadata_never_index").path) } ?? false)
    // 4. Wyszukiwanie w treści
    await s.searchContent("kluczowa"); check("szukanie w treści", s.searchHits.count >= 2, "\(s.searchHits.count) trafień")
    RamDisk.eject(); check("dysk RAM odmontowany", RamDisk.mount == nil && !(Process.mountList().contains("/preview-")))
    // 5. Dodawanie / usuwanie
    let extra = dir.appendingPathComponent("extra.txt"); try? "x".write(to: extra, atomically: true, encoding: .utf8)
    await s.addFiles([extra]); check("dodanie pliku", s.entries.contains { $0.path == "extra.txt" })
    await s.deleteEntries(["src/docs"]); check("usunięcie folderu", !s.entries.contains { $0.path.hasPrefix("src/docs") })
    // 6. Wrapped tar.xz
    await s.open(dir.appendingPathComponent("t.tar.xz"))
    check("tar.xz otwarty strumieniowo", s.entries.contains { $0.path.hasSuffix("big.txt") }, "\(s.entries.count) wpisów")
    await s.perform(.preview("src/docs/a.txt")); check("podgląd z tar.xz", s.previewItem != nil); s.previewItem = nil
    // 7. Kwarantanna + wypakowanie
    await s.open(dir.appendingPathComponent("t.zip"))
    let q = "0083;00000000;Safari;"; let archive = dir.appendingPathComponent("t.zip")
    _ = q.withCString { setxattr(archive.path, "com.apple.quarantine", $0, strlen($0), 0, 0) }
    let dest = dir.appendingPathComponent("out")
    await s.perform(.extract(dest, []))
    check("wypakowanie całości", fm.fileExists(atPath: dest.appendingPathComponent("src/big.txt").path))
    check("kwarantanna odziedziczona", Security.quarantine(of: dest.appendingPathComponent("src/big.txt")) != nil)
    let d2 = dir.appendingPathComponent("out2")
    await s.perform(.extract(d2, ["src/docs"]))
    check("wypakowanie wybranego folderu", fm.fileExists(atPath: d2.appendingPathComponent("src/docs/a.txt").path) && fm.fileExists(atPath: d2.appendingPathComponent("src/docs/deep/copy.txt").path), s.notice ?? "")
    let rowsDocs = s.rows; _ = rowsDocs
    let dd = Engine.extractBlocking(archive: archive, wrapped: false, password: nil, id: "src/docs", size: 100)
    check("przeciąganie folderu (RAM)", dd != nil && fm.fileExists(atPath: dd!.appendingPathComponent("a.txt").path), dd?.path ?? "nil")
    // Polskie znaki: nazwy NFC i hasło z „ą/ę/ł” (Foundation.Process normalizuje argumenty do NFD)
    do {
        let nfc = "Zdjęcia-Łódź".precomposedStringWithCanonicalMapping, pw = "Zażółć123!".precomposedStringWithCanonicalMapping
        let uni = dir.appendingPathComponent("uni")
        mkdir(uni.path, 0o755); mkdir(uni.path + "/" + nfc, 0o755)
        let fd = open(uni.path + "/" + nfc + "/plik.txt", O_CREAT | O_WRONLY, 0o644); _ = write(fd, "tresc", 5); close(fd)
        let mk = RawProcess(); mk.executableURL = Engine.sevenZip; mk.arguments = ["a", "-spd", "-p" + pw, dir.appendingPathComponent("uni.7z").path, nfc]; mk.currentDirectoryURL = uni
        mk.standardOutput = FileHandle.nullDevice; mk.standardError = FileHandle.nullDevice; mk.standardInput = FileHandle.nullDevice
        try? mk.run(); mk.waitUntilExit()
        await s.open(dir.appendingPathComponent("uni.7z"), password: pw)
        check("hasło z polskimi znakami", !s.entries.isEmpty, "\(s.entries.count) wpisów")
        let d4 = dir.appendingPathComponent("out4")
        await s.perform(.extract(d4, [nfc]))
        check("wypakowanie folderu z polskimi znakami", fm.fileExists(atPath: d4.appendingPathComponent(nfc + "/plik.txt").path), s.notice ?? "")
        let dd2 = Engine.extractBlocking(archive: dir.appendingPathComponent("uni.7z"), wrapped: false, password: pw, id: nfc, size: 10)
        check("przeciąganie folderu z polskimi znakami", dd2 != nil && fm.fileExists(atPath: dd2!.appendingPathComponent("plik.txt").path))
        await s.open(archive)
    }
    let multi = s.dragFiles(["src/docs/a.txt", "src/big.txt"]); check("dragFiles (wiele)", multi.count == 2 && multi[0].size > 0)
    for f in multi { let r = Engine.extractBlocking(archive: f.archive, wrapped: f.wrapped, password: f.password, id: f.id, size: f.size); check("przeciągnięcie \(f.name)", r != nil && fm.fileExists(atPath: r!.path)) }
    // 8. Porównanie z folderem, SHA, batch
    await s.compare(with: dest); check("porównanie z folderem", (s.diff?.same ?? 0) >= 4 && s.diff?.changed.isEmpty == true, s.diff.map { "same \($0.same) removed \($0.removed.count) added \($0.added.count)" } ?? "")
    let h = Engine.sha256(of: archive); let ref = RamDisk.sh("/usr/bin/shasum", ["-a", "256", archive.path]).1.split(separator: " ").first.map(String.init)
    check("SHA-256", h != nil && h == ref)
    s.batchURLs = [dir.appendingPathComponent("t.7z"), dir.appendingPathComponent("t.zip")]; s.batchDest = dir.appendingPathComponent("batch")
    await s.runBatch(); check("wsad", s.batchStatus.values.allSatisfy { $0 == "ok" }, "\(s.batchStatus.values)")
    await s.quickArchive([src]); check("szybkie archiwizowanie folderu", fm.fileExists(atPath: dir.appendingPathComponent("src.7z").path))
    s.extractHere([dir.appendingPathComponent("src.7z")]); try? await Task.sleep(for: .seconds(3))
    check("wypakuj tutaj", fm.fileExists(atPath: dir.appendingPathComponent("src/src/big.txt").path) || fm.fileExists(atPath: dir.appendingPathComponent("src 2/src/big.txt").path) || fm.fileExists(atPath: dir.appendingPathComponent("src-7z/src/big.txt").path) || ((try? fm.contentsOfDirectory(atPath: dir.path))?.contains { $0.hasPrefix("src") && $0 != "src" && $0 != "src.7z" } == true))
    do {
        let sg = dir.appendingPathComponent("t.zip")
        let so = Signer.sign(sg); check("podpis Ed25519", so != nil)
        if case .ok = Signer.verify(sg) { check("weryfikacja podpisu", true) } else { check("weryfikacja podpisu", false) }
        try? Data([1, 2, 3]).write(to: dir.appendingPathComponent("tamper.bin")); let tb = dir.appendingPathComponent("tamper.bin")
        _ = Signer.sign(tb); try? Data([9, 9]).write(to: tb)
        if case .changed = Signer.verify(tb) { check("wykrycie zmiany po podpisie", true) } else { check("wykrycie zmiany po podpisie", false) }
    }
    // 9. Estymacja
    let est = await Engine.estimate(files: [src]); check("estymacja", est.count == 4, est.map { "\($0.label):\($0.bytes)" }.joined(separator: " "))
    // Opcjonalnie: własne archiwum (ARCHIWUM_TEST_ARCHIVE=/ścieżka) — otwarcie, wypakowanie dwóch plików i przeciągnięcie
    if let path = ProcessInfo.processInfo.environment["ARCHIWUM_TEST_ARCHIVE"] {
        await s.open(URL(fileURLWithPath: path))
        let files = s.entries.filter { !$0.isDir }.prefix(2).map(\.path)
        print("archiwum użytkownika:", s.entries.count, "wpisów, typ", s.info.type, ", zaszyfrowane:", s.entries.contains { $0.encrypted }, ", prosi o hasło:", s.pendingOpen != nil)
        let dx = dir.appendingPathComponent("user-out")
        await s.perform(.extract(dx, Array(files)))
        check("własne archiwum: wypakowanie 2 plików", files.allSatisfy { fm.fileExists(atPath: dx.appendingPathComponent($0).path) }, "pending=\(s.pending != nil) notice=\(s.notice ?? "-")")
        let df = s.dragFiles(Array(files)); check("własne archiwum: dragFiles", df.count == files.count)
        for f in df { let r = Engine.extractBlocking(archive: f.archive, wrapped: f.wrapped, password: f.password, id: f.id, size: f.size); check("własne archiwum: przeciągnięcie \(f.name.prefix(12))…", r != nil && fm.fileExists(atPath: r!.path)) }
    }
    print(fails == 0 ? "WSZYSTKIE TESTY OK" : "BŁĘDY: \(fails)")
    RamDisk.eject()
    exit(fails == 0 ? 0 : 1)
}

extension Process {
    static func mountList() -> String { RamDisk.sh("/sbin/mount", []).1 }
}
