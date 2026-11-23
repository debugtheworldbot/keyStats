// Inject a burst of F18 key presses (no text side effects), then sample the
// KeyStats status item pixels from the real screen and print a timeline of
// how many saturated (tinted) pixels it shows.
// usage: menubar_probe <x> <y> <w> <h> <keys> <keysPerSecond> <sampleSeconds>
// x/y/w/h: status item frame on the primary display (global, top-left origin).
// Other displays show a *replica* of the menu bar with its own refresh path,
// so the same item is also probed on every other screen.
// Needs Accessibility (CGEventPost) and Screen Recording (screencapture)
// for the host app running this process.
import AppKit
import CoreGraphics

let a = CommandLine.arguments
guard a.count == 8 else { print("usage: x y w h keys kps sampleSeconds"); exit(2) }
let ix = Double(a[1])!, iy = Double(a[2])!, iw = Double(a[3])!, ih = Double(a[4])!
let primary = NSScreen.screens[0].frame
let pad = 16.0
var rects: [(String, String)] = []
for (i, screen) in NSScreen.screens.enumerated() {
    let f = screen.frame
    let fromRight = primary.maxX - ix          // items are right-aligned on each menu bar
    let x = f.maxX - fromRight - pad
    let top = primary.maxY - f.maxY            // convert to global top-left origin
    rects.append((i == 0 ? "primary" : "screen\(i)", "\(Int(x)),\(Int(top + iy)),\(Int(iw + pad * 2)),\(Int(ih))"))
}
let keys = Int(a[5])!, kps = Double(a[6])!, sampleSeconds = Double(a[7])!

func tintedPixels(_ rect: String) -> Int? {
    let path = "/tmp/ksverify/probe.png"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-R\(rect)", path]
    try? p.run(); p.waitUntilExit()
    guard p.terminationStatus == 0,
          let rep = NSImage(contentsOfFile: path)?.representations.first as? NSBitmapImageRep else { return nil }
    var n = 0
    for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.alphaComponent > 0.3 else { continue }
        if c.saturationComponent > 0.3 && c.brightnessComponent > 0.3 { n += 1 }
    }}
    return n
}

func sample() -> [Int]? {
    var r: [Int] = []
    for (_, rect) in rects { guard let n = tintedPixels(rect) else { return nil }; r.append(n) }
    return r
}
func fmt(_ v: [Int]) -> String { zip(rects, v).map { "\($0.0)=\($1)" }.joined(separator: " ") }

guard let base = sample() else { print("ERROR: screencapture failed (Screen Recording permission?)"); exit(1) }
print("rects: " + rects.map { "\($0.0)@\($0.1)" }.joined(separator: " "))
print("baseline " + fmt(base))
let src = CGEventSource(stateID: .hidSystemState)
let gap = UInt32(1_000_000 / kps)
for _ in 0..<keys {
    CGEvent(keyboardEventSource: src, virtualKey: 79, keyDown: true)?.post(tap: .cghidEventTap)
    usleep(5_000)
    CGEvent(keyboardEventSource: src, virtualKey: 79, keyDown: false)?.post(tap: .cghidEventTap)
    usleep(gap > 5_000 ? gap - 5_000 : 0)
}
let t0 = Date()
print("burst sent: \(keys) keys")
while Date().timeIntervalSince(t0) < sampleSeconds {
    if let v = sample() { print(String(format: "t+%.1fs ", Date().timeIntervalSince(t0)) + fmt(v)) }
    usleep(400_000)
}
if let v = sample() {
    let stuck = zip(zip(rects, v), base).filter { $0.0.1 > $0.1 + 4 }.map { "\($0.0.0.0)=\($0.0.1)" }
    print(stuck.isEmpty ? "RESULT: PASS (all screens returned to baseline)" : "RESULT: FAIL (still tinted: \(stuck.joined(separator: " ")))")
}
