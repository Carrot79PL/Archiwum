import SwiftUI
import AppKit
import Security

func fmt(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

func strength(_ p: String) -> (Double, String, Color) {
    guard !p.isEmpty else { return (0, "", .clear) }
    var pool = 0
    if p.contains(where: { $0.isLowercase }) { pool += 26 }
    if p.contains(where: { $0.isUppercase }) { pool += 26 }
    if p.contains(where: { $0.isNumber }) { pool += 10 }
    if p.contains(where: { !$0.isLetter && !$0.isNumber }) { pool += 30 }
    let bits = Double(p.count) * log2(Double(max(pool, 2)))
    switch bits {
    case ..<40: return (0.2, "Słabe", .red)
    case ..<60: return (0.45, "Średnie", .orange)
    case ..<80: return (0.7, "Dobre", .yellow)
    default: return (1, "Bardzo silne", .green)
    }
}

func generatePassword(_ n: Int = 20) -> String {
    let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#$%^&*-_=+")
    var bytes = [UInt8](repeating: 0, count: n)
    _ = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
    return String(bytes.map { alphabet[Int($0) % alphabet.count] })
}

struct GlassButton: View {
    var icon: String; var label: String; var colors: [Color] = Palette.blue; var compact = false
    @State private var hover = false
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold))
            if !compact { Text(label).font(.system(size: 14, weight: .semibold)) }
        }
        .accessibilityLabel(label)
        .brightness(hover ? 0.08 : 0).scaleEffect(hover ? 1.03 : 1).animation(.snappy(duration: 0.15), value: hover)
        .onHover { hover = $0 }
        .help(compact ? label : "")
        .foregroundStyle(.white)
        
        .padding(.horizontal, compact ? 12 : 16).padding(.vertical, 9)
        .background(Capsule().fill(LinearGradient(colors: colors.map { $0.opacity(0.85) }, startPoint: .topLeading, endPoint: .bottomTrailing)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1))
        .shadow(color: colors[1].opacity(0.4), radius: 8, y: 3)
        .contentShape(Capsule())
    }
}

struct PillIcon: View {
    var icon: String; var on = false; var label = ""
    var body: some View {
        Image(systemName: icon).font(.system(size: 13, weight: .semibold)).accessibilityLabel(label.isEmpty ? icon : label)
            .frame(width: 32, height: 32)
            .background(Circle().fill(.white.opacity(on ? 0.28 : 0.12)))
            .overlay(Circle().strokeBorder(.white.opacity(0.25)))
            .contentShape(Circle())
    }
}

extension View {
    func card() -> some View {
        padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.1)))
    }
}

struct RowView: View {
    var r: Row; var selected: Bool; var toggle: () -> Void = {}
    @State private var hover = false
    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggle) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.system(size: 18))
                    .foregroundStyle(selected ? Color.white : .white.opacity(0.4))
            }.buttonStyle(PressStyle()).help("Zaznacz (⌘/⇧ + klik zaznacza wiele)")
            Image(systemName: r.isDir ? "folder.fill" : Store.mediaExt.contains(r.ext) ? "photo.fill" : "doc.fill")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                .symbolEffect(.bounce, value: selected)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(LinearGradient(colors: r.isDir ? Palette.blue : Store.mediaExt.contains(r.ext) ? Palette.orange : [Color(white: 0.55), Color(white: 0.35)], startPoint: .topLeading, endPoint: .bottomTrailing)))
            VStack(alignment: .leading, spacing: 1) {
                Text(r.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                if !r.parent.isEmpty { Text(r.parent).font(.caption2).foregroundStyle(.white.opacity(0.5)).lineLimit(1).truncationMode(.head) }
                else if r.isDir { Text("\(r.count) plików").font(.caption2).foregroundStyle(.white.opacity(0.5)) }
            }
            if r.encrypted { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.orange) }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(fmt(r.size)).font(.system(size: 13)).foregroundStyle(.white.opacity(0.8)).monospacedDigit()
                if r.size > 0 && r.packed > 0 && !r.isDir { Text("→ \(fmt(r.packed))").font(.caption2).foregroundStyle(.white.opacity(0.45)).monospacedDigit() }
            }.frame(width: 90, alignment: .trailing)
            Text(r.modified).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).monospacedDigit().frame(width: 118, alignment: .trailing)
            if r.isDir { Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.white.opacity(0.4)) }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(selected ? 0.24 : hover ? 0.14 : 0.08)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(selected ? 0.5 : hover ? 0.22 : 0.10), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover).animation(.easeOut(duration: 0.12), value: selected)
    }
}

struct ContentView: View {
    @EnvironmentObject var s: Store
    @State private var sel = Set<String>()
    @State private var anchor: String?
    @State private var targeted = false
    @FocusState private var listFocus: Bool
    @FocusState private var searchFocus: Bool
    @State private var showWarn = false

    var hasList: Bool { !(s.url == nil || (s.entries.isEmpty && s.pendingOpen == nil)) }
    var selectedFiles: [Row] { s.rows.filter { sel.contains($0.id) && !$0.isDir } }

    var body: some View {
        VStack(spacing: 0) {
            header
            if hasList { listing } else { empty }
        }
        .frame(minWidth: 980, minHeight: 640)
        .foregroundStyle(.white)
        .background { GlassBackground(radius: 0) }
        .background(WindowGlass(onWindow: { w in s.attach(w) }))
        .navigationTitle(s.url?.lastPathComponent ?? "Archiwum")
        .environment(\.colorScheme, .dark)
        .onDrop(of: [.fileURL, .item], isTargeted: $targeted) { providers in s.handleProviders(providers) }
        .overlay {
            if targeted {
                ZStack {
                    RoundedRectangle(cornerRadius: 24).fill(Palette.blue[0].opacity(0.18))
                    RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.85), style: StrokeStyle(lineWidth: 3, dash: [10, 7]))
                    VStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.down.fill").font(.system(size: 44))
                        Text(hasList ? "Upuść, aby otworzyć lub utworzyć nowe archiwum" : "Upuść archiwum, aby je otworzyć — lub pliki, aby je spakować").font(.system(size: 15, weight: .semibold))
                    }
                }.padding(8).allowsHitTesting(false).transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: targeted)
        .sheet(isPresented: $s.showCreate) { CreateView() }
        .sheet(isPresented: $s.showExtract) { ExtractSheet() }
        .sheet(isPresented: $s.showDuplicates) { DuplicatesSheet() }
        .sheet(isPresented: $s.showConvert) { ConvertSheet() }
        .sheet(isPresented: $s.showBatch) { BatchSheet() }
        .sheet(isPresented: $s.showDiff) { DiffSheet() }
        .sheet(isPresented: $s.showSearch) { ContentSearchSheet() }
        .sheet(isPresented: $s.showHelp) { HelpSheet() }
        .sheet(isPresented: Binding(get: { s.videoURL != nil }, set: { if !$0 { s.videoURL = nil } })) {
            VStack(spacing: 10) {
                if let u = s.videoURL { VideoPlayerBox(url: u).frame(minWidth: 640, minHeight: 400).clipShape(RoundedRectangle(cornerRadius: 14)) }
                HStack { Text("Wideo odtwarzane z dysku RAM — nic nie trafia na dysk.").font(.caption).foregroundStyle(.white.opacity(0.55)); Spacer(); Button("Zamknij") { s.videoURL = nil }.keyboardShortcut(.cancelAction) }
            }.padding(18).foregroundStyle(.white).environment(\.colorScheme, .dark).presentationBackground { GlassBackground(radius: 0) }
        }
        .overlay { if s.busy != nil && s.progress != nil { ProgressOverlay().transition(.opacity) } }
        .overlay {
            if let b = s.busy, s.progress == nil {
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text(b).font(.system(size: 14, weight: .medium)) }
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(Capsule().fill(.ultraThinMaterial)).overlay(Capsule().strokeBorder(.white.opacity(0.25)))
                    .shadow(radius: 12).transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.snappy, value: s.busy)
        .overlay(alignment: .bottom) { if let r = s.result { ResultCard(r: r).id(r.id).padding(.bottom, 64).transition(.move(edge: .bottom).combined(with: .opacity)) } }
        .animation(.snappy, value: s.result?.id)
        .animation(.easeInOut(duration: 0.25), value: s.progress != nil)
        .sheet(item: $s.previewItem) { PreviewView(item: $0) }
        .sheet(isPresented: Binding(get: { s.pending != nil || s.pendingOpen != nil }, set: { if !$0 { s.pending = nil; s.pendingOpen = nil } })) {
            PasswordSheet(error: s.passwordError)
        }
        .confirmationDialog("Upuszczono \(s.dropChoice?.count ?? 0) elem.", isPresented: Binding(get: { s.dropChoice != nil }, set: { if !$0 { s.dropChoice = nil } }), titleVisibility: .visible) {
            if s.canModify { Button("Dodaj do „\(s.url?.lastPathComponent ?? "")”") { s.applyDrop(.add) } }
            Button("Utwórz nowe archiwum") { s.applyDrop(.create) }
            Button("Anuluj", role: .cancel) { s.dropChoice = nil }
        } message: { Text(s.canModify ? "Dodać do otwartego archiwum czy utworzyć nowe?" : "To archiwum jest tylko do odczytu — można utworzyć nowe.") }
        .alert("Usunąć z archiwum?", isPresented: Binding(get: { !s.deleteIDs.isEmpty }, set: { if !$0 { s.deleteIDs = [] } })) {
            Button("Usuń", role: .destructive) { let ids = s.deleteIDs; s.deleteIDs = []; sel = []; Task { await s.deleteEntries(ids) } }
            Button("Anuluj", role: .cancel) { s.deleteIDs = [] }
        } message: { Text("\(s.deleteIDs.count) elem. zostanie trwale usuniętych z pliku archiwum. Tej operacji nie można cofnąć.") }
        .alert("Archiwum", isPresented: Binding(get: { s.notice != nil && s.busy == nil && !["Wypakowano", "Archiwum jest", "Utworzono", "Dodano", "Usunięto"].contains { (s.notice ?? "").hasPrefix($0) } }, set: { if !$0 { s.notice = nil } })) {
            Button("OK") { s.notice = nil }
        } message: { Text(s.notice ?? "") }
    }

    // MARK: Nagłówek

    func headerRow(compact: Bool) -> some View {
        HStack(spacing: 10) {
            if !s.cwd.isEmpty {
                Button { s.cwd.removeLast(); sel = [] } label: { PillIcon(icon: "chevron.left", label: "W górę") }.buttonStyle(PressStyle()).keyboardShortcut("[", modifiers: .command)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(s.url?.lastPathComponent ?? "Archiwum").font(.system(size: 18, weight: .bold)).lineLimit(1)
                if hasList { Text(s.info.type.isEmpty ? "" : "\(s.info.type.uppercased()) · \(s.entries.filter { !$0.isDir }.count) plików").font(.caption).foregroundStyle(.white.opacity(0.55)) }
            }
            Spacer(minLength: 12)
            Button { s.createOpts = CreateOptions(); s.showCreate = true } label: { GlassButton(icon: "plus", label: "Nowe", colors: Palette.green, compact: compact) }.buttonStyle(PressStyle())
            if hasList, !selectedFiles.isEmpty {
                Button { Task { await s.perform(.open(Array(sel))) } } label: { GlassButton(icon: "arrow.up.forward.app", label: "Otwórz (\(sel.count))", colors: [Color(red: 0.95, green: 0.35, blue: 0.7), Palette.blue[1]], compact: compact) }.buttonStyle(PressStyle())
            }
            if hasList, s.migawka != nil {
                Button { s.openInMigawka() } label: { GlassButton(icon: "photo.on.rectangle", label: "Migawka", colors: [Color(red: 0.95, green: 0.35, blue: 0.7), Palette.blue[1]], compact: compact) }.buttonStyle(PressStyle())
                    .help("Otwórz całe archiwum w Migawce (zdjęcia i filmy)")
            }
            Button { s.openPanel() } label: { GlassButton(icon: "folder", label: "Archiwum", compact: compact) }.buttonStyle(PressStyle()).keyboardShortcut("o")
            if hasList {
                Button { s.choose(for: Array(sel)) } label: { GlassButton(icon: "arrow.down.doc", label: sel.isEmpty ? "Wypakuj" : "Wypakuj (\(sel.count))", colors: Palette.orange, compact: false) }
                    .buttonStyle(PressStyle()).keyboardShortcut("e", modifiers: .command)
                Button { Task { await s.perform(.test) } } label: { GlassButton(icon: "checkmark.shield", label: "Testuj", colors: [Color(white: 0.6), Color(white: 0.35)], compact: compact) }.buttonStyle(PressStyle())
            }
        }
    }

    var header: some View {
        VStack(spacing: 10) {
            ViewThatFits(in: .horizontal) { headerRow(compact: false); headerRow(compact: true) }
            if hasList { toolRow }
        }
        .padding(.leading, 84).padding(.trailing, 20).padding(.top, 14).padding(.bottom, 10)
    }

    var toolRow: some View {
        HStack(spacing: 8) {
            breadcrumb
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.6))
                TextField("Szukaj w archiwum", text: $s.query).textFieldStyle(.plain).focused($searchFocus).frame(width: 170)
                if !s.query.isEmpty { Button { s.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.5)) }.buttonStyle(PressStyle()) }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(.white.opacity(0.12))).overlay(Capsule().strokeBorder(.white.opacity(0.2)))
            Button("") { searchFocus = true }.keyboardShortcut("f", modifiers: .command).opacity(0).frame(width: 0)
            Menu {
                Picker("Sortuj", selection: $s.sortKey) { ForEach(SortKey.allCases) { Text($0.rawValue).tag($0) } }
                Divider()
                Toggle("Rosnąco", isOn: $s.ascending)
            } label: { PillIcon(icon: "arrow.up.arrow.down") }.menuStyle(.button).buttonStyle(PressStyle()).menuIndicator(.hidden).fixedSize().help("Sortowanie")
            if s.canModify {
                Button { s.addFiles() } label: { PillIcon(icon: "doc.badge.plus") }.buttonStyle(PressStyle()).help("Dodaj pliki do archiwum")
                Button { s.deleteIDs = Array(sel) } label: { PillIcon(icon: "trash") }.buttonStyle(PressStyle()).disabled(sel.isEmpty).opacity(sel.isEmpty ? 0.4 : 1).help("Usuń zaznaczone z archiwum")
            }
            Menu {
                Button("Konwertuj do innego formatu…") { s.convertOpts = CreateOptions(); s.showConvert = true }
                Button("Porównaj z innym archiwum lub folderem…") { s.comparePick() }
                Button("Szukaj w treści plików…") { s.showSearch = true }
                Button("Szukaj duplikatów") { s.showDuplicates = true }
                Divider()
                Button("Oblicz SHA-256") { s.computeSHA() }
                Button("Zapisz sumę SHA-256 (.sha256)") { s.writeSHAFile() }
                Button("Zweryfikuj z plikiem .sha256") { s.verifySHAFile() }
                Button("Podpisz cyfrowo (Ed25519)") { s.signArchive() }
                Button("Zweryfikuj podpis cyfrowy") { s.verifySignature() }
                Button("Eksportuj listę (CSV)…") { s.exportList() }
                Divider()
                Button("Ratuj dane z uszkodzonego archiwum…") { s.recover() }
                if let u = s.url, KeychainPW.exists(u.path) { Button("Zapomnij zapisane hasło") { KeychainPW.delete(u.path) } }
                Button("Zablokuj (zapomnij hasło)") { s.lock() }
                Button("Pomoc i skróty") { s.showHelp = true }
            } label: { PillIcon(icon: "ellipsis") }.menuStyle(.button).buttonStyle(PressStyle()).menuIndicator(.hidden).fixedSize().help("Więcej")
            Menu {
                Picker("Widok", selection: $s.viewMode) {
                    Label("Lista", systemImage: "list.bullet").tag(ViewMode.list)
                    Label("Miniatury", systemImage: "photo.on.rectangle").tag(ViewMode.thumbs)
                    Label("Mapa rozmiarów", systemImage: "square.grid.2x2").tag(ViewMode.treemap)
                }
            } label: { PillIcon(icon: s.viewMode == .list ? "list.bullet" : s.viewMode == .thumbs ? "photo.on.rectangle" : "square.grid.2x2.fill", on: s.viewMode != .list, label: "Widok") }
                .menuStyle(.button).buttonStyle(PressStyle()).menuIndicator(.hidden).fixedSize().help("Widok: lista, miniatury, mapa rozmiarów")
            if !s.warnings.isEmpty {
                Button { showWarn.toggle() } label: { PillIcon(icon: "exclamationmark.triangle.fill", on: true, label: "Ostrzeżenia bezpieczeństwa") }.buttonStyle(PressStyle())
                    .popover(isPresented: $showWarn) { WarningsPopover(warnings: s.warnings) }.help("Uwagi dotyczące bezpieczeństwa archiwum")
            }
            Button { withAnimation(.snappy) { s.showInspector.toggle() } } label: { PillIcon(icon: "sidebar.right", on: s.showInspector) }
                .buttonStyle(PressStyle()).keyboardShortcut("i", modifiers: .command).help("Panel informacji (⌘I)")
        }
    }

    var breadcrumb: some View {
        HStack(spacing: 4) {
            Button { s.cwd = []; sel = [] } label: { Label(s.baseName, systemImage: "archivebox").lineLimit(1) }.buttonStyle(PressStyle())
            ForEach(Array(s.cwd.enumerated()), id: \.offset) { i, c in
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.white.opacity(0.4))
                Button { s.cwd = Array(s.cwd.prefix(i + 1)); sel = [] } label: { Text(c).lineLimit(1) }.buttonStyle(PressStyle())
            }
            if !s.query.isEmpty { Text("· wyniki wyszukiwania").foregroundStyle(.white.opacity(0.55)) }
        }.font(.system(size: 13)).foregroundStyle(.white.opacity(0.85))
    }

    // MARK: Zawartość

    var empty: some View {
        VStack(spacing: 16) {
            Spacer()
            FloatingBadge()
            Text("Upuść archiwum lub pliki").font(.system(size: 24, weight: .bold))
            Text("7z · ZIP · RAR · TAR · GZ · BZ2 · XZ · ISO i inne\nUpuszczone pliki utworzą nowe archiwum")
                .multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.65))
            HStack(spacing: 12) {
                Button { s.openPanel() } label: { GlassButton(icon: "folder", label: "Otwórz archiwum…") }.buttonStyle(PressStyle())
                Button { s.createOpts = CreateOptions(); s.showCreate = true } label: { GlassButton(icon: "plus", label: "Nowe archiwum…", colors: Palette.green) }.buttonStyle(PressStyle())
                Button { s.recover() } label: { GlassButton(icon: "lifepreserver", label: "Ratuj dane", colors: [Color(white: 0.6), Color(white: 0.35)]) }.buttonStyle(PressStyle())
            }.padding(.top, 6)
            HStack(spacing: 14) {
                Label("Szyfrowanie AES-256", systemImage: "lock.shield")
                Label("Podgląd w pamięci", systemImage: "memorychip")
                Label("Dysk RAM, zero śladów", systemImage: "trash.slash")
            }.font(.caption).foregroundStyle(.white.opacity(0.55)).padding(.top, 6)
            Spacer()
        }.frame(maxWidth: .infinity)
    }

    func click(_ r: Row, rows: [Row]) {
        listFocus = true
        let m = NSEvent.modifierFlags
        if m.contains(.shift), let an = anchor, let i = rows.firstIndex(where: { $0.id == an }), let j = rows.firstIndex(where: { $0.id == r.id }) {
            sel = Set(rows[min(i, j)...max(i, j)].map(\.id))
        } else if m.contains(.command) {
            if sel.contains(r.id) { sel.remove(r.id) } else { sel.insert(r.id) }; anchor = r.id
        } else { sel = [r.id]; anchor = r.id }
    }

    func move(_ d: Int, _ rows: [Row]) {
        guard !rows.isEmpty else { return }
        let m = NSEvent.modifierFlags
        let cur = anchor.flatMap { a in rows.firstIndex(where: { $0.id == a }) } ?? (d > 0 ? -1 : rows.count)
        let n = min(max(cur + d, 0), rows.count - 1)
        if m.contains(.shift) {
            let a0 = sel.first.flatMap { f in rows.firstIndex(where: { $0.id == f }) } ?? n
            sel.insert(rows[n].id); _ = a0
        } else { sel = [rows[n].id] }
        anchor = rows[n].id
    }

    var columnHeader: some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: 18, height: 1)
            sortLabel("Nazwa", .name).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 48)
            sortLabel("Rozmiar", .size).frame(width: 90, alignment: .trailing)
            sortLabel("Zmieniony", .date).frame(width: 118, alignment: .trailing)
            Color.clear.frame(width: 10, height: 1)
        }.font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.55)).padding(.horizontal, 32).padding(.top, 2)
    }
    func sortLabel(_ t: String, _ k: SortKey) -> some View {
        Button { if s.sortKey == k { s.ascending.toggle() } else { s.sortKey = k; s.ascending = true } } label: {
            HStack(spacing: 3) { Text(t); if s.sortKey == k { Image(systemName: s.ascending ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold)) } }
                .foregroundStyle(s.sortKey == k ? .white.opacity(0.95) : .white.opacity(0.55))
        }.buttonStyle(PressStyle())
    }

    func activate(_ r: Row) {
        if r.isDir { s.cwd = r.id.split(separator: "/").map(String.init); sel = [] }
        else { Task { await s.perform(.open([r.id])) } }
    }

    var listing: some View {
        let rows = s.rows
        return HStack(spacing: 0) {
            VStack(spacing: 0) {
                if rows.isEmpty {
                    Spacer()
                    Text(s.query.isEmpty ? "Folder jest pusty" : "Brak wyników dla „\(s.query)”").foregroundStyle(.white.opacity(0.6))
                    Spacer()
                } else if s.viewMode == .thumbs {
                    ThumbGrid(rows: rows, sel: sel, onTap: { click($0, rows: rows) }, onOpen: { activate($0) })
                } else if s.viewMode == .treemap {
                    TreemapView(rows: s.treemapRows, sel: sel, onTap: { click($0, rows: rows) }, onOpen: { activate($0) })
                } else {
                    VStack(spacing: 0) {
                    columnHeader
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(rows) { r in
                                RowView(r: r, selected: sel.contains(r.id), toggle: { if sel.contains(r.id) { sel.remove(r.id) } else { sel.insert(r.id) }; anchor = r.id })
                                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)).combined(with: .offset(y: -6)), removal: .opacity))
                                    .draggable(containerItemID: r.id)
                                    .onTapGesture(count: 2) { activate(r) }
                                    .onTapGesture { click(r, rows: rows) }
                                    .contextMenu {
                                        if !r.isDir {
                                            Button("Otwórz (dysk RAM)") { Task { await s.perform(.open(sel.contains(r.id) ? Array(sel) : [r.id])) } }
                                            Button("Podgląd (Spacja)") { Task { await s.perform(.preview(r.id)) } }
                                        }
                                        if s.migawka != nil { Button("Otwórz archiwum w Migawce") { s.openInMigawka() } }
                                        Button("Wypakuj do…") { s.choose(for: sel.contains(r.id) ? Array(sel) : [r.id]) }
                                        Button("Kopiuj ścieżkę") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(r.id, forType: .string) }
                                        if s.canModify { Divider(); Button("Usuń z archiwum…", role: .destructive) { s.deleteIDs = sel.contains(r.id) ? Array(sel) : [r.id] } }
                                    }
                            }
                        }.padding(.horizontal, 20).padding(.vertical, 6)
                        .animation(.snappy(duration: 0.28), value: rows.map(\.id))
                        .dragContainerSelection(Array(sel))
                        .dragContainer(for: DragFile.self) { ids in MainActor.assumeIsolated { s.dragFiles(ids) } }
                    }
                    .focusable().focused($listFocus).focusEffectDisabled()
                    .onKeyPress(.upArrow) { move(-1, rows); return .handled }
                    .onKeyPress(.downArrow) { move(1, rows); return .handled }
                    .onKeyPress(.escape) { if !sel.isEmpty { sel = [] } else if !s.query.isEmpty { s.query = "" } else { return .ignored }; return .handled }
                    .onKeyPress(.space) {
                        if sel.count == 1, let r = rows.first(where: { $0.id == sel.first }), !r.isDir { Task { await s.perform(.preview(r.id)) }; return .handled }
                        return .ignored
                    }
                    .onKeyPress(.return) {
                        if sel.count == 1, let r = rows.first(where: { $0.id == sel.first }) { activate(r); return .handled }
                        if !sel.isEmpty { Task { await s.perform(.open(Array(sel))) }; return .handled }
                        return .ignored
                    }
                    .onKeyPress(.delete) { if s.canModify && !sel.isEmpty { s.deleteIDs = Array(sel); return .handled }; return .ignored }
                    .onKeyPress(.deleteForward) { if s.canModify && !sel.isEmpty { s.deleteIDs = Array(sel); return .handled }; return .ignored }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                statusBar(rows)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if s.showInspector {
                InspectorView(selection: sel).frame(width: 270).frame(maxHeight: .infinity, alignment: .top).transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background { Button("") { sel = Set(rows.map(\.id)) }.keyboardShortcut("a", modifiers: .command).opacity(0).allowsHitTesting(false) }
    }

    func statusBar(_ rows: [Row]) -> some View {
        HStack(spacing: 12) {
            if let b = s.busy {
                ProgressView(value: s.progress).frame(width: 180)
                Text(b)
                if let p = s.progress, p > 0.03, let t0 = s.jobStart {
                    let rem = Date().timeIntervalSince(t0) * (1 - p) / p
                    Text("\(Int(p * 100))% · ok. \(rem < 90 ? "\(Int(rem)) s" : "\(Int(rem / 60)) min")").foregroundStyle(.white.opacity(0.6)).monospacedDigit()
                }
                Button("Anuluj") { s.cancel() }.buttonStyle(.borderless)
                Spacer()
            } else {
                Text(sel.isEmpty ? "\(rows.count) elem." : "Zaznaczono \(sel.count) z \(rows.count)").foregroundStyle(.white.opacity(0.7))
                if !sel.isEmpty { Text(fmt(rows.filter { sel.contains($0.id) }.reduce(0) { $0 + $1.size })).foregroundStyle(.white.opacity(0.5)) }
                if s.isEncryptedArchive { Label("zaszyfrowane", systemImage: "lock.fill").labelStyle(.titleAndIcon).foregroundStyle(.white.opacity(0.6)) }
                Spacer()
                if let n = s.notice, ["Wypakowano", "Archiwum jest", "Utworzono", "Dodano", "Usunięto"].contains(where: { n.hasPrefix($0) }) { Text(n).foregroundStyle(.green) }
            }
        }
        .font(.system(size: 13)).padding(.horizontal, 18).padding(.vertical, 10)
        .background(Capsule().fill(.white.opacity(0.10))).overlay(Capsule().strokeBorder(.white.opacity(0.18)))
        .padding(.horizontal, 20).padding(.bottom, 14).padding(.top, 6)
    }
    @State private var _unused = 0
}

// MARK: Panel informacji

struct InspectorView: View {
    @EnvironmentObject var s: Store
    var selection: Set<String>

    func line(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).foregroundStyle(.white.opacity(0.55)); Spacer(minLength: 8)
            Text(v).multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(.system(size: 12))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                let rows = s.rows.filter { selection.contains($0.id) }
                if rows.count == 1, let r = rows.first { itemCard(r) }
                else if rows.count > 1 { multiCard(rows) }
                archiveCard
                typesCard
            }.padding(.trailing, 20).padding(.vertical, 6).padding(.leading, 4)
        }
    }

    func ratioBar(_ packed: Int64, _ size: Int64) -> some View {
        let ratio = size > 0 ? min(Double(packed) / Double(size), 1) : 1
        return VStack(alignment: .leading, spacing: 4) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule().fill(LinearGradient(colors: Palette.green, startPoint: .leading, endPoint: .trailing)).frame(width: max(6, g.size.width * ratio))
                }
            }.frame(height: 8)
            Text(size > 0 ? "Zajmuje \(Int(ratio * 100))% oryginału (oszczędność \(100 - Int(ratio * 100))%)" : "—").font(.caption2).foregroundStyle(.white.opacity(0.55))
        }
    }

    func itemCard(_ r: Row) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: r.isDir ? "folder.fill" : "doc.fill").foregroundStyle(r.isDir ? Palette.blue[0] : .white.opacity(0.8))
                Text(r.name).font(.system(size: 13, weight: .semibold)).lineLimit(2)
            }
            line("Typ", r.kind)
            line("Rozmiar", fmt(r.size)); line("Po spakowaniu", fmt(r.packed))
            if r.isDir { line("Plików", "\(r.count)") }
            if !r.modified.isEmpty { line("Zmieniony", r.modified) }
            if !r.created.isEmpty { line("Utworzony", r.created) }
            if !r.crc.isEmpty { line("CRC", r.crc) }
            if !r.method.isEmpty { line("Metoda", r.method) }
            if r.encrypted { line("Szyfrowanie", "tak") }
            line("Ścieżka", r.id)
            if !r.isDir { ratioBar(r.packed, r.size) }
        }.card()
    }

    func multiCard(_ rows: [Row]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Zaznaczono \(rows.count)").font(.system(size: 13, weight: .semibold))
            line("Rozmiar", fmt(rows.reduce(0) { $0 + $1.size }))
            line("Po spakowaniu", fmt(rows.reduce(0) { $0 + $1.packed }))
            ratioBar(rows.reduce(0) { $0 + $1.packed }, rows.reduce(0) { $0 + $1.size })
        }.card()
    }

    var archiveCard: some View {
        let files = s.entries.filter { !$0.isDir }
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        let disk = s.url.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int64 } ?? s.info.physical
        return VStack(alignment: .leading, spacing: 8) {
            Text("Archiwum").font(.system(size: 13, weight: .semibold))
            line("Format", s.info.type.isEmpty ? "—" : s.info.type.uppercased())
            if !s.info.method.isEmpty { line("Metoda", s.info.method) }
            if !s.info.solid.isEmpty { line("Solid", s.info.solid == "+" ? "tak" : "nie") }
            line("Rozmiar pliku", fmt(disk))
            line("Po rozpakowaniu", fmt(total))
            line("Plików / folderów", "\(files.count) / \(s.entries.count - files.count)")
            line("Szyfrowanie", s.entries.contains { $0.encrypted } ? (s.password != nil && s.entries.allSatisfy({ !$0.encrypted }) ? "nazwy" : "dane") : (s.password != nil ? "nazwy plików" : "brak"))
            if !s.info.comment.isEmpty { line("Komentarz", s.info.comment) }
            ratioBar(disk, total)
            let dups = s.duplicates
            if !dups.isEmpty {
                Button { s.showDuplicates = true } label: {
                    Label("Duplikaty: \(dups.count) grup", systemImage: "square.on.square").font(.system(size: 12, weight: .medium))
                }.buttonStyle(.glass).controlSize(.small)
            }
            HStack(spacing: 6) {
                if s.shaBusy { ProgressView().controlSize(.small); Text("Liczenie SHA-256…").font(.caption2).foregroundStyle(.white.opacity(0.6)) }
                else if let h = s.sha {
                    Text("SHA-256 " + h.prefix(16) + "…").font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(h, forType: .string) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(PressStyle()).help("Kopiuj pełną sumę")
                } else {
                    Button { s.computeSHA() } label: { Label("Suma SHA-256", systemImage: "number").font(.system(size: 12, weight: .medium)) }.buttonStyle(.glass).controlSize(.small)
                }
            }
            if s.canModify { Label("można modyfikować", systemImage: "pencil").font(.caption2).foregroundStyle(.white.opacity(0.5)) }
            else { Label("tylko do odczytu", systemImage: "lock").font(.caption2).foregroundStyle(.white.opacity(0.5)) }
        }.card()
    }

    var typesCard: some View {
        var by: [String: Int64] = [:]
        for e in s.entries where !e.isDir { by[(e.path as NSString).pathExtension.lowercased(), default: 0] += e.size }
        let top = by.sorted { $0.value > $1.value }.prefix(5)
        let mx = max(top.first?.value ?? 1, 1)
        return VStack(alignment: .leading, spacing: 7) {
            Text("Rodzaje plików").font(.system(size: 13, weight: .semibold))
            ForEach(Array(top), id: \.key) { k, v in
                HStack(spacing: 8) {
                    Text(k.isEmpty ? "brak" : k.uppercased()).font(.system(size: 11, weight: .medium)).frame(width: 44, alignment: .leading)
                    GeometryReader { g in Capsule().fill(LinearGradient(colors: Palette.blue, startPoint: .leading, endPoint: .trailing)).frame(width: max(4, g.size.width * CGFloat(v) / CGFloat(mx))) }.frame(height: 6)
                    Text(fmt(v)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).frame(width: 60, alignment: .trailing)
                }
            }
        }.card()
    }
}

// MARK: Arkusze

struct ExtractSheet: View {
    @EnvironmentObject var s: Store
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                GlyphBadge(symbol: "arrow.down.doc.fill", colors: Palette.orange, size: 48)
                VStack(alignment: .leading) {
                    Text("Wypakuj").font(.title2.bold())
                    Text(s.extractSel.isEmpty ? "Całe archiwum" : "\(s.extractSel.count) zaznaczonych elem.").foregroundStyle(.white.opacity(0.6))
                }
            }
            HStack {
                Image(systemName: "folder").foregroundStyle(.white.opacity(0.6))
                Text(s.extractDest?.path ?? "—").lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Zmień…") { s.pickDestination() }
            }.card()
            Toggle("Do podfolderu „\(s.baseName)”", isOn: $s.subfolder)
            Picker("Gdy plik już istnieje", selection: $s.overwrite) { ForEach(Overwrite.allCases) { Text($0.rawValue).tag($0) } }
            Toggle("Pokaż w Finderze po zakończeniu", isOn: $s.revealAfter)
            HStack {
                Spacer()
                Button("Anuluj", role: .cancel) { s.showExtract = false }.keyboardShortcut(.cancelAction)
                Button("Wypakuj") { s.runExtract() }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 480).foregroundStyle(.white).environment(\.colorScheme, .dark)
        .presentationBackground { GlassBackground(tint: Palette.orange[0], radius: 0) }
    }
}

struct PasswordSheet: View {
    @EnvironmentObject var s: Store
    var error: Bool
    @State private var pw = ""
    @State private var show = false
    var body: some View {
        VStack(spacing: 14) {
            GlyphBadge(symbol: "lock.fill", colors: error ? Palette.orange : Palette.green)
            Text("Archiwum jest zaszyfrowane").font(.headline)
            if error { Text("Nieprawidłowe hasło. Spróbuj ponownie.").foregroundStyle(.red).font(.callout) }
            Group { if show { TextField("Hasło", text: $pw) } else { SecureField("Hasło", text: $pw) } }
                .textFieldStyle(.roundedBorder).frame(width: 260).onSubmit(go)
            Toggle("Pokaż hasło", isOn: $show).toggleStyle(.checkbox)
            Toggle("Zapamiętaj w Pęku kluczy (odblokowanie Touch ID)", isOn: $s.rememberPW).toggleStyle(.checkbox).font(.caption)
            HStack {
                Button("Anuluj", role: .cancel) { s.pending = nil; s.pendingOpen = nil }
                Button("OK", action: go).buttonStyle(.glassProminent).keyboardShortcut(.defaultAction).disabled(pw.isEmpty)
            }
        }.padding(28).frame(minWidth: 340).foregroundStyle(.white).environment(\.colorScheme, .dark)
        .presentationBackground { GlassBackground(tint: error ? Palette.orange[0] : Palette.green[0], radius: 0) }
    }
    func go() { let p = pw; Task { await s.submitPassword(p) } }
}

struct CreateView: View {
    @EnvironmentObject var s: Store
    @State private var showPw = false
    var o: Binding<CreateOptions> { $s.createOpts }
    var pw: String { s.createOpts.password }
    var ok: Bool { !s.createOpts.files.isEmpty && (pw.isEmpty || pw == s.createConfirm) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nowe archiwum").font(.title2.bold())
            GroupBox {
                List {
                    ForEach(s.createOpts.files, id: \.self) { u in
                        Label(u.lastPathComponent, systemImage: u.hasDirectoryPath ? "folder.fill" : "doc")
                    }.onDelete { s.createOpts.files.remove(atOffsets: $0) }
                }.scrollContentBackground(.hidden).frame(height: min(CGFloat(s.createOpts.files.count) * 30 + 30, 110))
                    .overlay { if s.createOpts.files.isEmpty { Text("Upuść tutaj pliki lub użyj „Dodaj…”").foregroundStyle(.secondary) } }
                    .dropDestination(for: URL.self) { urls, _ in s.createOpts.files += urls; return true }
                HStack { Button("Dodaj…") { add() }; Spacer(); Text("\(s.createOpts.files.count) elem.").foregroundStyle(.secondary) }
            }
            Form {
                Picker("Format", selection: o.format) { ForEach(Format.allCases) { Text($0.label).tag($0) } }
                Picker("Kompresja", selection: o.level) { ForEach(Level.allCases) { Text($0.label).tag($0) } }
                if s.createOpts.format == .sevenZ || s.createOpts.format == .zip {
                    Picker("Metoda", selection: o.method) {
                        ForEach(Method.allCases.filter { s.createOpts.format == .sevenZ || $0 != .lzma2 }) { Text($0.label).tag($0) }
                    }
                    if s.createOpts.format == .sevenZ { Toggle("Archiwum ciągłe (solid) — lepsza kompresja", isOn: o.solid) }
                    if s.createOpts.level == .extreme && s.createOpts.format == .sevenZ {
                        Picker("Słownik", selection: o.dictMB) { ForEach([64, 128, 256, 512, 1024], id: \.self) { Text("\($0) MB").tag($0) } }
                        Text("Pakowanie zajmie ok. \(String(format: "%.1f", Double(s.createOpts.dictMB) * 10.5 / 1024)) GB RAM, rozpakowanie ok. \(s.createOpts.dictMB) MB. Największy zysk przy dużych zestawach podobnych plików.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("Podziel na części", selection: o.volumeMB) {
                        Text("Nie dziel").tag(0); Text("100 MB").tag(100); Text("700 MB (CD)").tag(700); Text("1 GB").tag(1000); Text("4 GB (FAT32)").tag(4000)
                    }
                }
                Toggle("Pomiń pliki systemowe (.DS_Store, ._*)", isOn: o.excludeSystem)
                if s.createOpts.format.supportsPassword { Toggle("Zweryfikuj archiwum po utworzeniu", isOn: o.verify) }
                Toggle("Przenieś oryginały do Kosza po utworzeniu", isOn: o.trashOriginals)
                if s.createOpts.format.supportsPassword {
                    HStack {
                        if showPw { TextField("Hasło", text: o.password) } else { SecureField("Hasło", text: o.password) }
                        Button("Generuj") { let g = generatePassword(); s.createOpts.password = g; s.createConfirm = g; showPw = true }
                    }
                    if showPw { TextField("Powtórz", text: $s.createConfirm) } else { SecureField("Powtórz", text: $s.createConfirm) }
                    let st = strength(pw)
                    if !pw.isEmpty {
                        HStack { ProgressView(value: st.0).tint(st.2); Text(st.1).font(.caption).foregroundStyle(st.2).frame(width: 80, alignment: .leading) }
                    }
                    Toggle("Pokaż hasło", isOn: $showPw)
                    if s.createOpts.format == .sevenZ { Toggle("Szyfruj też nazwy plików", isOn: o.encryptNames) }
                    else { Text("ZIP: szyfrowanie AES-256").font(.caption).foregroundStyle(.secondary) }
                    if !pw.isEmpty && pw != s.createConfirm { Text("Hasła się różnią").foregroundStyle(.red).font(.caption) }
                } else { Text("Ten format nie obsługuje szyfrowania — użyj 7z lub ZIP.").font(.caption).foregroundStyle(.secondary) }
            }.formStyle(.grouped).scrollContentBackground(.hidden).frame(minHeight: 260, maxHeight: 340)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Button("Oszacuj wynik (próbka)") { s.runEstimate() }.disabled(s.createOpts.files.isEmpty || s.estimating)
                    if s.estimating { ProgressView().controlSize(.small) }
                    Text("Szybki test na próbce plików — nic nie jest zapisywane.").font(.caption).foregroundStyle(.white.opacity(0.5))
                }
                ForEach(s.estimates) { e in
                    HStack(spacing: 8) {
                        Text(e.label).font(.system(size: 11)).frame(width: 140, alignment: .leading)
                        GeometryReader { g in Capsule().fill(LinearGradient(colors: Palette.green, startPoint: .leading, endPoint: .trailing)).frame(width: max(4, g.size.width * e.ratio)) }.frame(height: 6)
                        Text("~\(fmt(e.bytes)) (\(Int(e.ratio * 100))%)").font(.system(size: 11)).frame(width: 110, alignment: .trailing).monospacedDigit()
                    }
                }
            }
            HStack {
                Spacer()
                Button("Anuluj", role: .cancel) { s.showCreate = false; s.createConfirm = "" }
                Button("Utwórz…") { Task { await s.create() } }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction).disabled(!ok)
            }
        }.padding(22).frame(width: 520).foregroundStyle(.white).environment(\.colorScheme, .dark)
        .presentationBackground { GlassBackground(radius: 0) }
    }
    func add() {
        let p = NSOpenPanel(); p.canChooseFiles = true; p.canChooseDirectories = true; p.allowsMultipleSelection = true
        if p.runModal() == .OK { s.createOpts.files += p.urls }
    }
}


struct ConvertSheet: View {
    @EnvironmentObject var s: Store
    var o: Binding<CreateOptions> { $s.convertOpts }
    @State private var confirm = ""
    var ok: Bool { s.convertOpts.password.isEmpty || s.convertOpts.password == confirm }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                GlyphBadge(symbol: "arrow.triangle.2.circlepath", colors: Palette.blue, size: 48)
                VStack(alignment: .leading) {
                    Text("Konwertuj archiwum").font(.title2.bold())
                    Text("Zawartość trafia na dysk RAM, nic nie jest zapisywane na dysku.").font(.caption).foregroundStyle(.white.opacity(0.6))
                }
            }
            Form {
                Picker("Nowy format", selection: o.format) { ForEach(Format.allCases) { Text($0.label).tag($0) } }
                Picker("Kompresja", selection: o.level) { ForEach(Level.allCases) { Text($0.label).tag($0) } }
                if s.convertOpts.format.supportsPassword {
                    SecureField("Hasło (opcjonalnie)", text: o.password)
                    SecureField("Powtórz", text: $confirm)
                    if s.convertOpts.format == .sevenZ { Toggle("Szyfruj też nazwy plików", isOn: o.encryptNames) }
                }
                Toggle("Zweryfikuj po utworzeniu", isOn: o.verify)
            }.formStyle(.grouped).scrollContentBackground(.hidden).frame(height: 290)
            Text("Wymaga tyle wolnej pamięci RAM, ile zajmuje rozpakowana zawartość.").font(.caption).foregroundStyle(.white.opacity(0.5))
            HStack {
                Spacer()
                Button("Anuluj", role: .cancel) { s.showConvert = false }.keyboardShortcut(.cancelAction)
                Button("Konwertuj…") { Task { await s.convert() } }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction).disabled(!ok)
            }
        }.padding(24).frame(width: 500).foregroundStyle(.white).environment(\.colorScheme, .dark)
        .presentationBackground { GlassBackground(radius: 0) }
    }
}

struct BatchSheet: View {
    @EnvironmentObject var s: Store
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                GlyphBadge(symbol: "square.stack.3d.down.right.fill", colors: Palette.orange, size: 48)
                VStack(alignment: .leading) {
                    Text("Wypakuj wiele archiwów").font(.title2.bold())
                    Text("\(s.batchURLs.count) archiwów").foregroundStyle(.white.opacity(0.6))
                }
            }
            ScrollView {
                VStack(spacing: 5) {
                    ForEach(s.batchURLs, id: \.self) { u in
                        HStack {
                            Image(systemName: "archivebox").foregroundStyle(.white.opacity(0.6))
                            Text(u.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            switch s.batchStatus[u] {
                            case "…": ProgressView().controlSize(.small)
                            case "ok": Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.green[0])
                            case "hasło": Label("hasło", systemImage: "lock.fill").font(.caption).foregroundStyle(.orange)
                            case "błąd": Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                            default: EmptyView()
                            }
                        }.font(.system(size: 13)).padding(.horizontal, 10).padding(.vertical, 6)
                         .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.08)))
                    }
                }
            }.frame(height: min(CGFloat(s.batchURLs.count) * 34 + 6, 190))
            HStack { Image(systemName: "folder").foregroundStyle(.white.opacity(0.6)); Text(s.batchDest?.path ?? "—").lineLimit(1).truncationMode(.middle); Spacer(); Button("Zmień…") { s.pickBatchDest() }.disabled(s.batchRunning) }.card()
            Toggle("Każde archiwum do osobnego podfolderu", isOn: $s.subfolder)
            Picker("Gdy plik już istnieje", selection: $s.overwrite) { ForEach(Overwrite.allCases) { Text($0.rawValue).tag($0) } }
            HStack {
                Text("Archiwa z hasłem zostaną pominięte.").font(.caption).foregroundStyle(.white.opacity(0.5))
                Spacer()
                Button("Zamknij") { s.showBatch = false }.keyboardShortcut(.cancelAction).disabled(s.batchRunning)
                Button("Wypakuj wszystkie") { Task { await s.runBatch() } }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction).disabled(s.batchRunning || s.batchDest == nil)
            }
        }.padding(24).frame(width: 520).foregroundStyle(.white).environment(\.colorScheme, .dark)
        .presentationBackground { GlassBackground(tint: Palette.orange[0], radius: 0) }
    }
}
