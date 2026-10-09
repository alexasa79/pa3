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

let ink = color(0x292B29), skin = color(0xFAEEDD), paper = color(0xDDD7CA)

for (name, size) in sizes {
    let image = drawAppIcon(size: size)
    try writePNG(image, to: iconset.appendingPathComponent(name))
}

try writePNG(drawMenuIcon(size: 36), to: resources.appendingPathComponent("MenuBarIcon.png"))

func drawAppIcon(size: CGFloat) -> NSImage {
  // Explicit pixels avoid Retina backing-scale doubling the iconset sizes.
  let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  defer { NSGraphicsContext.restoreGraphicsState() }
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
  let transform = NSAffineTransform()
  transform.translateX(by: size * 62 / 1024, yBy: size * 62 / 1024)
  transform.scale(by: size * 900 / (1024 * 460))
  transform.concat()
  portrait()
  let image = NSImage(size: NSSize(width: size, height: size))
  image.addRepresentation(bitmap)
  return image
}

func color(_ hex: UInt32) -> NSColor {
  NSColor(
    srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
    blue: CGFloat(hex & 255) / 255, alpha: 1)
}
func oval(_ r: NSRect, _ c: NSColor) {
  c.setFill()
  NSBezierPath(ovalIn: r).fill()
}
func line(_ points: [NSPoint], _ width: CGFloat, _ c: NSColor) {
  let p = NSBezierPath()
  p.lineWidth = width
  p.lineCapStyle = .round
  p.lineJoinStyle = .round
  p.move(to: points[0])
  for q in points.dropFirst() { p.line(to: q) }
  c.setStroke()
  p.stroke()
}
func wave(x: CGFloat, y: CGFloat, size: CGFloat) {
  // Requested unibrow: y = cos(x), x from 0 through 3*pi; preserve aspect and rounded ends.
  var pts: [NSPoint] = []
  for i in 0...96 {
    let t = CGFloat(i) / 96
    pts.append(
      NSPoint(x: x + size * (0.1 + 0.8 * t), y: y + size * (0.5 + cos(t * 3 * .pi) * 0.12)))
  }
  line(pts, size * 0.073, ink)
}
func portrait() {
  NSGraphicsContext.saveGraphicsState()
  paper.setFill()
  NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 460, height: 460), xRadius: 90, yRadius: 90)
    .fill()
  oval(NSRect(x: 66, y: 160, width: 56, height: 90), skin)
  oval(NSRect(x: 338, y: 160, width: 56, height: 90), skin)
  oval(NSRect(x: 94, y: 88, width: 272, height: 322), skin)
  let beard = NSBezierPath()
  beard.move(to: NSPoint(x: 94, y: 220))
  beard.curve(
    to: NSPoint(x: 134, y: 190), controlPoint1: NSPoint(x: 101, y: 187),
    controlPoint2: NSPoint(x: 112, y: 184))
  beard.curve(
    to: NSPoint(x: 230, y: 178), controlPoint1: NSPoint(x: 178, y: 218),
    controlPoint2: NSPoint(x: 194, y: 206))
  beard.curve(
    to: NSPoint(x: 326, y: 190), controlPoint1: NSPoint(x: 266, y: 206),
    controlPoint2: NSPoint(x: 282, y: 218))
  beard.curve(
    to: NSPoint(x: 366, y: 220), controlPoint1: NSPoint(x: 348, y: 184),
    controlPoint2: NSPoint(x: 359, y: 187))
  beard.curve(
    to: NSPoint(x: 230, y: 58), controlPoint1: NSPoint(x: 374, y: 90),
    controlPoint2: NSPoint(x: 310, y: 58))
  beard.curve(
    to: NSPoint(x: 94, y: 220), controlPoint1: NSPoint(x: 150, y: 58),
    controlPoint2: NSPoint(x: 86, y: 90))
  beard.close()
  ink.setFill()
  beard.fill()
  oval(NSRect(x: 163, y: 228, width: 15, height: 20), ink)
  oval(NSRect(x: 282, y: 228, width: 15, height: 20), ink)
  let nose = NSBezierPath()
  nose.move(to: NSPoint(x: 228, y: 229))
  nose.curve(
    to: NSPoint(x: 242, y: 207), controlPoint1: NSPoint(x: 214, y: 211),
    controlPoint2: NSPoint(x: 218, y: 201))
  nose.lineWidth = 6
  nose.lineCapStyle = .round
  ink.setStroke()
  nose.stroke()
  let smile = NSBezierPath()
  smile.move(to: NSPoint(x: 203, y: 166))
  smile.curve(
    to: NSPoint(x: 257, y: 166), controlPoint1: NSPoint(x: 219, y: 147),
    controlPoint2: NSPoint(x: 241, y: 147))
  smile.lineWidth = 8
  smile.lineCapStyle = .round
  skin.setStroke()
  smile.stroke()
  // Inset the complete brow within the forehead, with generous margins on both sides.
  let waveSize: CGFloat = 195
  wave(x: 230 - waveSize / 2, y: 301 - waveSize / 2, size: waveSize)
  NSGraphicsContext.restoreGraphicsState()
}

func drawMenuIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()

    NSColor.black.setStroke()
    let midY = size * 0.50

    let wave = NSBezierPath()
    wave.lineWidth = max(2.0, size * 0.073)
    wave.lineCapStyle = .round
    wave.lineJoinStyle = .round

    let startX = size * 0.10
    let endX = size * 0.90
    let amplitude = size * 0.12
    let segments = 96

    for index in 0...segments {
        let progress = CGFloat(index) / CGFloat(segments)
        let phase = progress * 4.0 * .pi
        let point = NSPoint(
            x: startX + (endX - startX) * progress,
            y: midY + sin(phase) * amplitude
        )

        if index == 0 {
            wave.move(to: point)
        } else {
            wave.line(to: point)
        }
    }
    wave.stroke()

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
