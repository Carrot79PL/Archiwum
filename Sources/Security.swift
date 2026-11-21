import Foundation
import AppKit
import CryptoKit
import LocalAuthentication
import UserNotifications

enum Security {
    static let execExt: Set<String> = ["app", "command", "sh", "pkg", "mpkg", "exe", "bat", "cmd", "scr", "jar", "workflow", "terminal", "dylib", "scpt", "applescript", "js", "vbs", "msi", "dmg"]

    /// Heuristic check of an archive listing for dangerous / suspicious content.
    static func analyze(entries: [Entry], archiveSize: Int64) -> [String] {
        var w: [String] = []
        let total = entries.reduce(Int64(0)) { $0 + $1.size }
        if total > 1 << 30, archiveSize > 0, total / max(archiveSize, 1) > 200 {
            w.append("Możliwa bomba kompresji: po rozpakowaniu \(fmt(total)) (\(total / max(archiveSize, 1))× rozmiaru pliku).")
        }
        if entries.count > 200_000 { w.append("Bardzo dużo pozycji (\(entries.count)) — rozpakowanie może być długie i obciążyć dysk.") }
        let bad = entries.filter { $0.path.hasPrefix("/") || $0.path.split(separator: "/").contains("..") }
        if !bad.isEmpty { w.append("\(bad.count) ścieżek próbuje wyjść poza folder docelowy (../ lub ścieżka bezwzględna). Silnik je neutralizuje, ale archiwum jest podejrzane.") }
        if entries.contains(where: { $0.path.split(separator: "/").count > 50 }) { w.append("Nienaturalnie głębokie zagnieżdżenie folderów (>50).") }
        let links = entries.filter { $0.attrs.hasPrefix("l") || $0.attrs.contains(" l") }
        if !links.isEmpty { w.append("Zawiera \(links.count) dowiązań symbolicznych (mogą wskazywać poza archiwum).") }
        let ex = entries.filter { !$0.isDir && (execExt.contains(($0.path as NSString).pathExtension.lowercased()) || $0.path.contains(".app/Contents/MacOS/")) }
        if !ex.isEmpty { w.append("Zawiera \(ex.count) programów lub skryptów wykonywalnych — nie uruchamiaj ich, jeśli nie ufasz źródłu.") }
        return w
    }

    static let quarantineKey = "com.apple.quarantine"
    static func quarantine(of url: URL) -> Data? {
        let n = getxattr(url.path, quarantineKey, nil, 0, 0, 0)
        guard n > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: n)
        guard getxattr(url.path, quarantineKey, &buf, n, 0, 0) == n else { return nil }
        return Data(buf)
    }
    /// Files extracted from a quarantined (downloaded) archive inherit the quarantine flag, like in Archive Utility.
    static func propagateQuarantine(_ q: Data, to root: URL, names: [String]) {
        func set(_ u: URL) { q.withUnsafeBytes { _ = setxattr(u.path, quarantineKey, $0.baseAddress, q.count, 0, 0) } }
        for n in Set(names.map { String($0.split(separator: "/").first ?? "") }) where !n.isEmpty {
            let top = root.appendingPathComponent(n)
            guard FileManager.default.fileExists(atPath: top.path) else { continue }
            set(top)
            if let en = FileManager.default.enumerator(at: top, includingPropertiesForKeys: nil) { for case let f as URL in en { set(f) } }
        }
    }

    static func freeSpace(at url: URL) -> Int64? {
        var u = url
        while !FileManager.default.fileExists(atPath: u.path), u.path != "/" { u = u.deletingLastPathComponent() }
        return (try? u.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }
}

// MARK: Pęk kluczy + Touch ID (opcjonalne zapamiętanie hasła)

enum KeychainPW {
    static func account(_ path: String) -> String { SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func q(_ path: String) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "pl.local.archiwum", kSecAttrAccount as String: account(path)] }
    static let marksKey = "kpAccounts"
    static func marked(_ path: String) -> Bool { (UserDefaults.standard.stringArray(forKey: marksKey) ?? []).contains(account(path)) }
    static func mark(_ path: String, _ on: Bool) {
        var l = Set(UserDefaults.standard.stringArray(forKey: marksKey) ?? [])
        if on { l.insert(account(path)) } else { l.remove(account(path)) }
        UserDefaults.standard.set(Array(l), forKey: marksKey)
    }
    static func save(_ path: String, _ pw: String) {
        var query = q(path); SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = Data(pw.utf8)
        if SecItemAdd(query as CFDictionary, nil) == errSecSuccess { mark(path, true) }
    }
    /// Does not touch the Keychain at all unless the user previously chose to remember a password for this archive.
    static func exists(_ path: String) -> Bool { marked(path) }
    static func load(_ path: String) -> String? {
        var query = q(path); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func delete(_ path: String) { SecItemDelete(q(path) as CFDictionary); mark(path, false) }
}

enum Biometric {
    static func authenticate(_ reason: String) async -> Bool {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return false }
        return (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}

enum Notifier {
    static func post(_ title: String, _ body: String) {
        guard !NSApplication.shared.isActive else { return }
        let c = UNUserNotificationCenter.current()
        c.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            let m = UNMutableNotificationContent(); m.title = title; m.body = body
            c.add(UNNotificationRequest(identifier: UUID().uuidString, content: m, trigger: nil))
        }
    }
}

// MARK: Usługi systemowe (menu Usługi / Szybkie akcje)

final class ServicesProvider: NSObject {
    static let shared = ServicesProvider()
    func urls(_ pb: NSPasteboard) -> [URL] { (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? [] }
    @objc func archiveFolder(_ pb: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let u = urls(pb); guard !u.isEmpty else { return }
        DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true); Task { await Store.shared.quickArchive(u) } }
    }
    @objc func compress(_ pb: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let u = urls(pb)
        DispatchQueue.main.async { Store.shared.createOpts = CreateOptions(); Store.shared.createOpts.files = u; Store.shared.showCreate = true; NSApp.activate(ignoringOtherApps: true) }
    }
    @objc func extractHere(_ pb: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let u = urls(pb); guard !u.isEmpty else { return }
        DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true); Store.shared.extractHere(u) }
    }
    @objc func openArchive(_ pb: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let u = urls(pb).first else { return }
        DispatchQueue.main.async { Task { await Store.shared.open(u) }; NSApp.activate(ignoringOtherApps: true) }
    }
}


// MARK: Podpisy cyfrowe archiwów (Ed25519)

enum Signer {
    struct Sig: Codable { var version = 1; var sha256: String; var publicKey: String; var signature: String; var signedAt: String; var file: String }
    static let service = "pl.local.archiwum.sign"
    /// Tests use an in-memory key so they never touch the user's Keychain.
    nonisolated(unsafe) static var ephemeral: Curve25519.Signing.PrivateKey?

    static func privateKey() -> Curve25519.Signing.PrivateKey {
        if let e = ephemeral { return e }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "ed25519",
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data, let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: d) { return k }
        let k = Curve25519.Signing.PrivateKey()
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "ed25519",
                                  kSecValueData as String: k.rawRepresentation]
        SecItemAdd(add as CFDictionary, nil)
        return k
    }
    /// Reads the signing key only if it already exists (verification must never create one or prompt needlessly).
    static func existingKey() -> Curve25519.Signing.PrivateKey? {
        if let e = ephemeral { return e }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "ed25519",
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return try? Curve25519.Signing.PrivateKey(rawRepresentation: d)
    }
    static func fingerprint(_ pub: Data) -> String {
        SHA256.hash(data: pub).prefix(8).map { String(format: "%02x", $0) }.joined(separator: ":")
    }
    static var myFingerprint: String { fingerprint(privateKey().publicKey.rawRepresentation) }

    static func sign(_ archive: URL) -> URL? {
        guard let h = Engine.sha256(of: archive) else { return nil }
        let k = privateKey()
        guard let sig = try? k.signature(for: Data(h.utf8)) else { return nil }
        let rec = Sig(sha256: h, publicKey: k.publicKey.rawRepresentation.base64EncodedString(), signature: sig.base64EncodedString(),
                      signedAt: ISO8601DateFormatter().string(from: Date()), file: archive.lastPathComponent)
        let out = archive.appendingPathExtension("sig")
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(rec), (try? data.write(to: out)) != nil else { return nil }
        return out
    }

    enum Verdict { case ok(mine: Bool, fp: String, date: String), changed, badSignature, missing, unreadable }
    static func verify(_ archive: URL) -> Verdict {
        let sigURL = archive.appendingPathExtension("sig")
        guard FileManager.default.fileExists(atPath: sigURL.path) else { return .missing }
        guard let d = try? Data(contentsOf: sigURL), let rec = try? JSONDecoder().decode(Sig.self, from: d),
              let pub = Data(base64Encoded: rec.publicKey), let sig = Data(base64Encoded: rec.signature),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pub) else { return .unreadable }
        guard key.isValidSignature(sig, for: Data(rec.sha256.utf8)) else { return .badSignature }
        guard let h = Engine.sha256(of: archive), h == rec.sha256 else { return .changed }
        return .ok(mine: existingKey().map { $0.publicKey.rawRepresentation == pub } ?? false, fp: fingerprint(pub), date: rec.signedAt)
    }
}
