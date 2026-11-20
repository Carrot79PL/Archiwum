import AppKit
let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let r = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: r, xRadius: 185, yRadius: 185)
NSGraphicsContext.current?.saveGraphicsState()
let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.35); sh.shadowBlurRadius = 30; sh.shadowOffset = NSSize(width: 0, height: -12); sh.set()
NSGradient(colors: [NSColor(red: 0.35, green: 0.55, blue: 1, alpha: 1), NSColor(red: 0.55, green: 0.30, blue: 0.95, alpha: 1)])!.draw(in: path, angle: -55)
NSGraphicsContext.current?.restoreGraphicsState()
let gloss = NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), .clear])!
gloss.draw(in: NSBezierPath(roundedRect: NSRect(x: 100, y: 512, width: 824, height: 412), xRadius: 185, yRadius: 185), angle: -90)
NSColor.white.withAlphaComponent(0.35).setStroke(); path.lineWidth = 3; path.stroke()
let cfg = NSImage.SymbolConfiguration(pointSize: 430, weight: .semibold).applying(.init(paletteColors: [.white]))
if let sym = NSImage(systemSymbolName: "archivebox.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    let sz = sym.size
    sym.draw(in: NSRect(x: (S - sz.width) / 2, y: (S - sz.height) / 2 - 10, width: sz.width, height: sz.height))
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
