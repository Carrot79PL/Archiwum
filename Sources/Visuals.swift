import SwiftUI
import AppKit

// MARK: Animacja pakowania / rozpakowywania

struct FlyingFiles: View {
    var unpack: Bool
    @Environment(\.accessibilityReduceMotion) private var reduce
    private let icons = ["doc.fill", "photo.fill", "folder.fill", "film.fill", "doc.text.fill", "music.note", "curlybraces"]
    private let colors: [Color] = [Palette.blue[0], Palette.orange[0], Palette.green[0], Color(red: 0.95, green: 0.35, blue: 0.7), .white, Palette.blue[1], Palette.orange[1]]

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = reduce ? 0 : ctx.date.timeIntervalSinceReferenceDate
            GeometryReader { g in
                let w = g.size.width, h = g.size.height
                let boxX = unpack ? 40.0 : w - 40
                ZStack {
                    ForEach(0..<icons.count, id: \.self) { i in
                        let f = (t * 0.42 + Double(i) / Double(icons.count)).truncatingRemainder(dividingBy: 1)
                        let x = unpack ? 70 + (w - 110) * f : 40 + (w - 110) * f
                        let y = h / 2 + sin(f * .pi * 2 + Double(i)) * 14
                        let scale = unpack ? 0.35 + 0.65 * f : 1 - 0.65 * pow(f, 3)
                        let fade = min(f * 7, 1) * min((1 - f) * 7, 1)
                        Image(systemName: icons[i]).font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(colors[i]).scaleEffect(scale).opacity(fade).rotationEffect(.degrees(sin(f * .pi * 2) * 14))
                            .position(x: x, y: y)
                    }
                    ForEach(0..<2, id: \.self) { k in
                        let ph = (t * 0.7 + Double(k) * 0.5).truncatingRemainder(dividingBy: 1)
                        Circle().strokeBorder(Palette.blue[0].opacity(0.5 * (1 - ph)), lineWidth: 2)
                            .frame(width: 40 + 70 * ph, height: 40 + 70 * ph).position(x: boxX, y: h / 2)
                    }
                    Image(systemName: unpack ? "archivebox" : "archivebox.fill").font(.system(size: 46, weight: .semibold))
                        .foregroundStyle(LinearGradient(colors: Palette.blue, startPoint: .top, endPoint: .bottom))
                        .shadow(color: Palette.blue[1].opacity(0.7), radius: 10 + 6 * sin(t * 5))
                        .scaleEffect(1 + 0.06 * sin(t * 5))
                        .position(x: boxX, y: h / 2)
                }
            }
        }
    }
}

struct Shimmer: View {
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduce)) { ctx in
            GeometryReader { g in
                let ph = reduce ? 0.5 : ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                LinearGradient(colors: [.clear, .white.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 60).offset(x: -60 + (g.size.width + 60) * ph)
            }
        }
    }
}

struct ProgressOverlay: View {
    @EnvironmentObject var s: Store
    var body: some View {
        let p = s.progress ?? 0
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                Text(s.job.title).font(.system(size: 18, weight: .bold))
                FlyingFiles(unpack: s.job == .unpack || s.job == .test).frame(height: 84)
                Text("\(Int(p * 100))%").font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText()).animation(.snappy, value: Int(p * 100))
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.14))
                        Capsule().fill(LinearGradient(colors: Palette.blue + Palette.green, startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(10, g.size.width * p)).animation(.linear(duration: 0.25), value: p)
                            .overlay { Shimmer().clipShape(Capsule()) }
                    }
                }.frame(height: 10)
                Text(s.currentFile.isEmpty ? " " : s.currentFile).font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity)
                HStack {
                    if p > 0.03, let t0 = s.jobStart {
                        let rem = Date().timeIntervalSince(t0) * (1 - p) / p
                        Label("ok. \(rem < 90 ? "\(Int(rem)) s" : "\(Int(rem / 60)) min")", systemImage: "clock").font(.caption).foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer()
                    Button("Anuluj") { s.cancel() }.buttonStyle(.glass)
                }
            }
            .padding(24).frame(width: 460).foregroundStyle(.white)
            .background(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(.ultraThinMaterial))
            .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(.white.opacity(0.3)))
            .shadow(radius: 30)
        }
    }
}

// MARK: Karta wyniku z animacją

struct ResultCard: View {
    var r: JobResult
    @EnvironmentObject var s: Store
    @State private var drawn: CGFloat = 0
    @State private var pop = false
    @State private var burst = false

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            ZStack {
                Circle().stroke(.white.opacity(0.15), lineWidth: 5)
                Circle().trim(from: 0, to: drawn).stroke(LinearGradient(colors: Palette.green, startPoint: .top, endPoint: .bottom), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: r.icon).font(.system(size: 24, weight: .bold)).foregroundStyle(LinearGradient(colors: Palette.green, startPoint: .top, endPoint: .bottom))
                    .scaleEffect(pop ? 1 : 0.2).opacity(pop ? 1 : 0)
                ForEach(0..<10, id: \.self) { i in
                    Circle().fill(i % 2 == 0 ? Palette.green[0] : Palette.blue[0]).frame(width: 5, height: 5)
                        .offset(x: burst ? cos(Double(i) * .pi / 5) * 46 : 0, y: burst ? sin(Double(i) * .pi / 5) * 46 : 0)
                        .opacity(burst ? 0 : 1)
                }
            }.frame(width: 64, height: 64).overlay(alignment: .top) { Confetti().offset(y: -8) }
            VStack(alignment: .leading, spacing: 6) {
                Text(r.title).font(.system(size: 17, weight: .bold))
                if !r.detail.isEmpty { Text(r.detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.65)).lineLimit(1).truncationMode(.middle) }
                if !r.lines.isEmpty {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 2) {
                        ForEach(Array(r.lines.enumerated()), id: \.offset) { _, l in
                            GridRow { Text(l.0).foregroundStyle(.white.opacity(0.55)); Text(l.1).lineLimit(1).truncationMode(.middle) }.font(.system(size: 12))
                        }
                    }.padding(.top, 2)
                }
                HStack {
                    if let u = r.reveal { Button("Pokaż w Finderze") { NSWorkspace.shared.activateFileViewerSelecting([u]) }.buttonStyle(.glass) }
                    Button("OK") { s.result = nil }.buttonStyle(.glassProminent)
                }.padding(.top, 4)
            }
        }
        .padding(20).frame(width: 460, alignment: .leading).foregroundStyle(.white)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(0.3)))
        .shadow(radius: 24)
        .onAppear {
            withAnimation(.easeOut(duration: 0.7)) { drawn = 1 }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.55).delay(0.35)) { pop = true }
            withAnimation(.easeOut(duration: 0.9).delay(0.4)) { burst = true }
        }
    }
}

// MARK: Mapa rozmiarów (treemap)

func tileColors(_ r: Row) -> [Color] {
    if r.isDir { return Palette.blue }
    switch r.ext {
    case _ where Store.mediaExt.contains(r.ext): return ["mp4","mov","m4v","mkv","avi","webm","mpg","mpeg","3gp","mts"].contains(r.ext) ? [Color(red: 0.95, green: 0.35, blue: 0.7), Palette.blue[1]] : Palette.orange
    case "pdf", "doc", "docx", "txt", "md", "rtf", "pages", "xls", "xlsx", "csv", "ppt", "pptx": return Palette.green
    case "zip", "7z", "rar", "gz", "xz", "bz2", "tar", "dmg", "iso": return [Color(red: 0.6, green: 0.3, blue: 0.9), Color(red: 0.35, green: 0.2, blue: 0.7)]
    case "swift", "js", "py", "c", "h", "cpp", "java", "html", "css", "json", "xml", "sh": return [Color(red: 0.2, green: 0.7, blue: 0.8), Color(red: 0.1, green: 0.4, blue: 0.6)]
    default: return [Color(white: 0.55), Color(white: 0.32)]
    }
}

struct TreemapView: View {
    var rows: [Row]; var sel: Set<String>
    var onTap: (Row) -> Void; var onOpen: (Row) -> Void

    func layout(_ items: [Row], in rect: CGRect) -> [(Row, CGRect)] {
        let vals = items.filter { $0.size > 0 }.sorted { $0.size > $1.size }
        let total = vals.reduce(0.0) { $0 + Double($1.size) }
        guard total > 0, rect.width > 1, rect.height > 1 else { return [] }
        let scale = Double(rect.width * rect.height) / total
        func worst(_ a: [Double], _ side: Double) -> Double {
            let s = a.reduce(0, +); let mx = a.max()!, mn = a.min()!
            return max(side * side * mx / (s * s), s * s / (side * side * mn))
        }
        var out: [(Row, CGRect)] = []; var r = rect; var i = 0
        while i < vals.count {
            let side = Double(min(r.width, r.height))
            var row = [vals[i]]; var j = i + 1
            while j < vals.count {
                let cur = row.map { Double($0.size) * scale }
                if worst(cur + [Double(vals[j].size) * scale], side) <= worst(cur, side) { row.append(vals[j]); j += 1 } else { break }
            }
            let areas = row.map { Double($0.size) * scale }; let sum = areas.reduce(0, +)
            if r.width >= r.height {
                let w = CGFloat(sum / Double(r.height)); var y = r.minY
                for (k, it) in row.enumerated() { let h = CGFloat(areas[k] / Double(w)); out.append((it, CGRect(x: r.minX, y: y, width: w, height: h))); y += h }
                r = CGRect(x: r.minX + w, y: r.minY, width: max(r.width - w, 0), height: r.height)
            } else {
                let h = CGFloat(sum / Double(r.width)); var x = r.minX
                for (k, it) in row.enumerated() { let w = CGFloat(areas[k] / Double(h)); out.append((it, CGRect(x: x, y: r.minY, width: w, height: h))); x += w }
                r = CGRect(x: r.minX, y: r.minY + h, width: r.width, height: max(r.height - h, 0))
            }
            i = j
        }
        return out
    }

    var body: some View {
        GeometryReader { g in
            let tiles = layout(rows, in: CGRect(x: 0, y: 0, width: g.size.width, height: g.size.height))
            ZStack(alignment: .topLeading) {
                ForEach(tiles, id: \.0.id) { r, rect in
                    let selected = sel.contains(r.id)
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(LinearGradient(colors: tileColors(r).map { $0.opacity(0.85) }, startPoint: .topLeading, endPoint: .bottomTrailing))
                        RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(selected ? 0.95 : 0.25), lineWidth: selected ? 3 : 1)
                        if rect.width > 64 && rect.height > 36 {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.name).font(.system(size: 12, weight: .semibold)).lineLimit(rect.height > 70 ? 2 : 1)
                                Text(fmt(r.size)).font(.system(size: 10)).opacity(0.75)
                            }.padding(7).foregroundStyle(.white)
                        }
                    }
                    .frame(width: max(rect.width - 3, 1), height: max(rect.height - 3, 1))
                    .position(x: rect.midX, y: rect.midY)
                    .help("\(r.name) — \(fmt(r.size))")
                    .onTapGesture(count: 2) { onOpen(r) }
                    .onTapGesture { onTap(r) }
                    .transition(.scale.combined(with: .opacity))
                }
                if tiles.isEmpty { Text("Brak danych o rozmiarach").foregroundStyle(.white.opacity(0.6)).frame(width: g.size.width, height: g.size.height) }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 6)
        .animation(.snappy, value: rows.map(\.id))
    }
}

// MARK: Duplikaty

struct DuplicatesSheet: View {
    @EnvironmentObject var s: Store
    var body: some View {
        let groups = s.duplicates
        let wasted = groups.reduce(Int64(0)) { $0 + $1[0].size * Int64($1.count - 1) }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                GlyphBadge(symbol: "square.on.square", colors: Palette.orange, size: 48)
                VStack(alignment: .leading) {
                    Text("Duplikaty w archiwum").font(.title2.bold())
                    Text(groups.isEmpty ? "Nie znaleziono identycznych plików" : "\(groups.count) grup · do odzyskania \(fmt(wasted))").foregroundStyle(.white.opacity(0.6))
                }
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, g in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(g.count) kopii · \(fmt(g[0].size)) każda").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.orange[0])
                            ForEach(Array(g.enumerated()), id: \.offset) { i, e in
                                HStack(spacing: 6) {
                                    Image(systemName: i == 0 ? "checkmark.circle.fill" : "doc.on.doc").foregroundStyle(i == 0 ? Palette.green[0] : .white.opacity(0.5))
                                    Text(e.path).lineLimit(1).truncationMode(.middle).font(.system(size: 12))
                                }
                            }
                        }.card()
                    }
                }
            }.frame(height: min(CGFloat(groups.count) * 74 + 6, 280))
            Text("Porównanie po sumie CRC i rozmiarze. Pierwsza kopia w każdej grupie zostaje.").font(.caption).foregroundStyle(.white.opacity(0.5))
            HStack {
                Spacer()
                Button("Zamknij") { s.showDuplicates = false }.keyboardShortcut(.cancelAction)
                if s.canModify && !groups.isEmpty {
                    Button("Usuń kopie…") { s.deleteIDs = groups.flatMap { $0.dropFirst().map(\.path) }; s.showDuplicates = false }.buttonStyle(.glassProminent)
                }
            }
        }.padding(24).frame(width: 540).foregroundStyle(.white).environment(\.colorScheme, .dark)
        .presentationBackground { GlassBackground(tint: Palette.orange[0], radius: 0) }
    }
}

// MARK: Ustawienia

struct SettingsView: View {
    @AppStorage("sound") private var sound = true
    @AppStorage("autoLock") private var autoLock = 5
    var body: some View {
        Form {
            Toggle("Dźwięk po zakończeniu operacji", isOn: $sound)
            Picker("Automatyczna blokada hasła po bezczynności", selection: $autoLock) {
                Text("1 minuta").tag(1); Text("5 minut").tag(5); Text("15 minut").tag(15); Text("Nigdy").tag(0)
            }
            Text("Po blokadzie hasło jest zapominane, a przy zaszyfrowanych nazwach plików lista archiwum zostaje zamknięta. Dysk RAM z otwartymi plikami jest wtedy odmontowywany.")
                .font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped).frame(width: 460, height: 230)
    }
}


/// Unosząca się ikona z orbitującymi cząsteczkami (ekran startowy).
struct FloatingBadge: View {
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduce)) { ctx in
            let t = reduce ? 0 : ctx.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<8, id: \.self) { i in
                    let a = t * (0.5 + Double(i % 3) * 0.15) + Double(i) * .pi / 4
                    let rad = 78.0 + 10 * sin(t + Double(i))
                    Image(systemName: ["doc.fill", "photo.fill", "folder.fill", "film.fill"][i % 4])
                        .font(.system(size: 13)).foregroundStyle([Palette.blue[0], Palette.orange[0], Palette.green[0], Color.white][i % 4].opacity(0.75))
                        .offset(x: cos(a) * rad * 1.25, y: sin(a) * rad * 0.55)
                        .scaleEffect(0.7 + 0.3 * (sin(a) + 1) / 2).opacity(0.35 + 0.5 * (sin(a) + 1) / 2)
                }
                GlyphBadge(symbol: "archivebox.fill", colors: Palette.blue, size: 110)
                    .offset(y: sin(t * 1.4) * 6)
            }.frame(height: 150)
        }
    }
}

/// Konfetti na karcie wyniku.
struct Confetti: View {
    @State private var fall = false
    private let colors: [Color] = [Palette.green[0], Palette.blue[0], Palette.orange[0], Color(red: 0.95, green: 0.35, blue: 0.7), .white, Palette.blue[1]]
    var body: some View {
        ZStack {
            ForEach(0..<26, id: \.self) { i in
                let r1 = abs(sin(Double(i) * 12.9898)), r2 = abs(sin(Double(i) * 78.233)), r3 = abs(sin(Double(i) * 39.425))
                RoundedRectangle(cornerRadius: 1.5).fill(colors[i % colors.count]).frame(width: 5 + r1 * 4, height: 8 + r2 * 5)
                    .rotationEffect(.degrees(fall ? 360 * (r3 * 2 - 1) * 2 : 0))
                    .offset(x: fall ? (r1 - 0.5) * 340 : 0, y: fall ? 70 + r2 * 110 : -16)
                    .opacity(fall ? 0 : 1)
                    .animation(.easeOut(duration: 1.3 + r3).delay(0.35 + r2 * 0.25), value: fall)
            }
        }.allowsHitTesting(false).onAppear { fall = true }
    }
}
