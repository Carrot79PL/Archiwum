import SwiftUI
import AppKit

/// Many windows, one archive each. Keeps track of live stores and routes “open this” requests.
@MainActor enum Registry {
    private final class Box { weak var s: Store?; init(_ s: Store) { self.s = s } }
    private static var boxes: [Box] = []
    static weak var active: Store?
    static var openWindow: (() -> Void)?
    static var pending: [URL] = []

    static func add(_ s: Store) { boxes.removeAll { $0.s == nil }; boxes.append(Box(s)) }
    static var all: [Store] { boxes.compactMap(\.s) }
    static var current: Store? { active ?? all.first }

    static func withStore(_ f: @escaping (Store) -> Void) {
        if let c = current { f(c); return }
        openWindow?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if let c = current { f(c) } }
    }

    static func isEmpty(_ s: Store) -> Bool { s.url == nil && s.pendingOpen == nil && s.busy == nil }

    /// Opens in `s` if it is empty, otherwise in a new window.
    static func route(_ u: URL, in s: Store) {
        if isEmpty(s) {
            Task { await s.open(u) }
            for o in all where o !== s && isEmpty(o) { o.window?.close() }
        } else { openInNewWindow(u) }
    }
    static func openInNewWindow(_ u: URL) { pending.append(u); openWindow?() }
    static func consumePending(for s: Store) {
        guard !pending.isEmpty, isEmpty(s) else { return }
        let u = pending.removeFirst(); Task { await s.open(u) }
    }
}

struct WindowRoot: View {
    @StateObject private var store = Store()
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        ContentView()
            .environmentObject(store)
            .onOpenURL { u in Registry.route(u, in: store) }
            .onAppear {
                Registry.openWindow = { openWindow(id: "main") }
                Registry.consumePending(for: store)
            }
    }
}

/// What was dragged from another Archiwum window (internal drags carry file promises; resolving them extracts to the RAM disk).
struct DropChoice { var urls: [URL] = []; var drags: [DragFile] = []; var count: Int { urls.count + drags.count } }

enum DragState {
    nonisolated(unsafe) static var items: [DragFile] = []
    nonisolated(unsafe) static var sourceID: UUID?
    nonisolated(unsafe) static var at = Date.distantPast
    static func set(_ i: [DragFile], from id: UUID) { items = i; sourceID = id; at = Date() }
    static func clear() { items = []; sourceID = nil; at = .distantPast }
    static var fresh: Bool { Date().timeIntervalSince(at) < 60 && !items.isEmpty }
}

extension Store {
    func handleProviders(_ providers: [NSItemProvider]) -> Bool {
        if DragState.fresh {
            if DragState.sourceID == id { return false }          // dropped back on its own window: ignore
            let items = DragState.items; DragState.clear()
            dropChoice = DropChoice(drags: items); return true
        }
        Task {
            var urls: [URL] = []
            for p in providers where p.canLoadObject(ofClass: URL.self) {
                let u: URL? = await withCheckedContinuation { c in _ = p.loadObject(ofClass: URL.self) { obj, _ in c.resume(returning: obj) } }
                if let u { urls.append(u) }
            }
            handleDrop(urls)
        }
        return true
    }

    enum DropAction { case add, create }
    func applyDrop(_ a: DropAction) {
        guard let d = dropChoice else { return }
        dropChoice = nil
        Task {
            var urls = d.urls
            if !d.drags.isEmpty {
                busy = "Przygotowanie plików…"
                let extra = await Task.detached { d.drags.compactMap { Engine.extractBlocking(archive: $0.archive, wrapped: $0.wrapped, password: $0.password, id: $0.id, size: $0.size) } }.value
                busy = nil; urls += extra
            }
            guard !urls.isEmpty else { notice = "Nie udało się przygotować przeciągniętych plików."; return }
            switch a {
            case .add: await addFiles(urls)
            case .create: createOpts = CreateOptions(); createOpts.files = urls; showCreate = true
            }
        }
    }
}
