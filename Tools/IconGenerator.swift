import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("Assets/PA3.iconset", isDirectory: true)
let resources = root.appendingPathComponent("Assets", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

let sizes: [(String, CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (name, size) in sizes {
    let image = drawAppIcon(size: size)
    try writePNG(image, to: iconset.appendingPathComponent(name))
}

try writePNG(drawMenuIcon(size: 36), to: resources.appendingPathComponent("MenuBarIcon.png"))

func drawAppIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    rect.fill()

    let bg = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.06, dy: size * 0.06), xRadius: size * 0.22, yRadius: size * 0.22)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.05, green: 0.10, blue: 0.16, alpha: 1),
        NSColor(calibratedRed: 0.05, green: 0.28, blue: 0.34, alpha: 1)
    ])?.draw(in: bg, angle: -35)

    NSColor(calibratedRed: 0.20, green: 0.82, blue: 0.70, alpha: 1).setStroke()
    let wave = NSBezierPath()
    wave.lineWidth = size * 0.045
    wave.lineCapStyle = .round
    wave.lineJoinStyle = .round
    let midY = size * 0.50
    let startX = size * 0.18
    let step = size * 0.10
    wave.move(to: NSPoint(x: startX, y: midY))
    wave.curve(
        to: NSPoint(x: startX + step * 2, y: midY),
        controlPoint1: NSPoint(x: startX + step * 0.45, y: midY + size * 0.16),
        controlPoint2: NSPoint(x: startX + step * 1.55, y: midY - size * 0.16)
    )
    wave.curve(
        to: NSPoint(x: startX + step * 4, y: midY),
        controlPoint1: NSPoint(x: startX + step * 2.45, y: midY + size * 0.20),
        controlPoint2: NSPoint(x: startX + step * 3.55, y: midY - size * 0.20)
    )
    wave.curve(
        to: NSPoint(x: startX + step * 6.2, y: midY),
        controlPoint1: NSPoint(x: startX + step * 4.55, y: midY + size * 0.16),
        controlPoint2: NSPoint(x: startX + step * 5.65, y: midY - size * 0.16)
    )
    wave.stroke()

    let micRect = NSRect(x: size * 0.39, y: size * 0.32, width: size * 0.22, height: size * 0.40)
    let mic = NSBezierPath(roundedRect: micRect, xRadius: size * 0.10, yRadius: size * 0.10)
    NSColor(calibratedWhite: 0.98, alpha: 1).setFill()
    mic.fill()

    NSColor(calibratedRed: 0.05, green: 0.10, blue: 0.16, alpha: 1).setStroke()
    let grille = NSBezierPath()
    grille.lineWidth = max(1, size * 0.012)
    for offset in [0.42, 0.50, 0.58] {
        grille.move(to: NSPoint(x: size * 0.44, y: size * offset))
        grille.line(to: NSPoint(x: size * 0.56, y: size * offset))
    }
    grille.stroke()

    NSColor(calibratedWhite: 0.98, alpha: 1).setStroke()
    let stand = NSBezierPath()
    stand.lineWidth = size * 0.035
    stand.lineCapStyle = .round
    stand.move(to: NSPoint(x: size * 0.50, y: size * 0.30))
    stand.line(to: NSPoint(x: size * 0.50, y: size * 0.22))
    stand.move(to: NSPoint(x: size * 0.40, y: size * 0.21))
    stand.line(to: NSPoint(x: size * 0.60, y: size * 0.21))
    stand.stroke()

    return image
}

func drawMenuIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()

    NSColor.black.setStroke()
    let bars: [(x: CGFloat, h: CGFloat)] = [
        (0.28, 0.34),
        (0.42, 0.70),
        (0.56, 0.46),
        (0.70, 0.62)
    ]
    for bar in bars {
        let path = NSBezierPath()
        path.lineWidth = max(2.6, size * 0.090)
        path.lineCapStyle = .round
        let x = size * bar.x
        let half = size * bar.h * 0.5
        path.move(to: NSPoint(x: x, y: size * 0.5 - half))
        path.line(to: NSPoint(x: x, y: size * 0.5 + half))
        path.stroke()
    }

    let baseline = NSBezierPath()
    baseline.lineWidth = max(1.4, size * 0.045)
    baseline.lineCapStyle = .round
    baseline.move(to: NSPoint(x: size * 0.18, y: size * 0.50))
    baseline.line(to: NSPoint(x: size * 0.80, y: size * 0.50))
    baseline.stroke()

    return image
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconGenerator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to encode PNG"])
    }
    try png.write(to: url)
}
