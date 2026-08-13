#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation

// Draws the app mark and writes it out as PNG and SVG.
//
//     swift Tools/IconGen/icon.swift <output-directory>
//
// An original speaking-head silhouette — the same idea as 🗣️, drawn here rather
// than traced from Apple's glyph, which is their artwork and not ours to ship.
//
// Geometry lives in `Mark` as normalised 0…1 coordinates so the PNG and the SVG
// are emitted from one description and cannot drift.

enum Mark {

    /// Head profile, facing right. Normalised to the artwork box, y down.
    ///
    /// Traced as a silhouette rather than assembled from circles: a profile is
    /// what makes it read as *speaking* rather than as a generic avatar, and the
    /// nose and chin are the two features that survive at 16pt.
    static let head: [Segment] = [
        // Back of the neck, rising to the base of the skull.
        .move(0.30, 0.95),
        .curve(to: (0.26, 0.74), c1: (0.295, 0.88), c2: (0.27, 0.80)),
        // Back of the skull, over the crown, down the forehead.
        // c1 continues the tangent of the segment above rather than cutting
        // straight for the skull — otherwise the join reads as a notch in the
        // neck at every size.
        .curve(to: (0.16, 0.44), c1: (0.245, 0.65), c2: (0.16, 0.53)),
        .curve(to: (0.42, 0.10), c1: (0.16, 0.24), c2: (0.25, 0.10)),
        .curve(to: (0.64, 0.34), c1: (0.57, 0.10), c2: (0.64, 0.20)),
        // Brow into the bridge of the nose.
        .curve(to: (0.625, 0.44), c1: (0.64, 0.39), c2: (0.615, 0.41)),
        // Nose.
        .curve(to: (0.745, 0.55), c1: (0.64, 0.47), c2: (0.745, 0.505)),
        .curve(to: (0.635, 0.59), c1: (0.745, 0.58), c2: (0.68, 0.59)),
        // Lips, chin, jaw.
        .curve(to: (0.655, 0.71), c1: (0.635, 0.645), c2: (0.675, 0.67)),
        .curve(to: (0.50, 0.805), c1: (0.63, 0.765), c2: (0.565, 0.805)),
        // Front of the neck.
        .line(0.50, 0.95),
        .close,
    ]

    static let waveCentre = (x: 0.665, y: 0.575)
    /// Swept symmetrically about horizontal, in degrees.
    static let waveSpread = 46.0

    /// Arcs off the mouth, thinned out as the icon shrinks.
    ///
    /// Three arcs occupy about four pixels at 16pt and merge into a grey smear.
    /// An iconset carries separate artwork per size, so the small ones drop arcs
    /// and thicken what is left rather than rendering detail that cannot land.
    static func waves(atPixelSize size: Double) -> (radii: [Double], width: Double) {
        switch size {
        // One arc, pushed right out: at 16pt the gap between the nose and the
        // arc has to clear a whole pixel or the two render as one blob.
        case ..<24: ([0.245], 0.075)
        case ..<48: ([0.135, 0.245], 0.062)
        default: ([0.115, 0.185, 0.255], 0.038)
        }
    }

    enum Segment {
        case move(Double, Double)
        case line(Double, Double)
        case curve(to: (Double, Double), c1: (Double, Double), c2: (Double, Double))
        case close
    }
}

// MARK: - Layout

/// macOS app icons are a rounded rect inset inside a larger transparent canvas.
/// These are Apple's proportions: an 824pt shape on a 1024pt canvas.
let canvas = 1024.0
let plateInset = 100.0
let plateCorner = 185.0
/// The mark inside the plate, as a fraction of the plate.
let markScale = 0.88

// MARK: - Drawing

func drawIcon(into ctx: CGContext, size: Double) {
    let s = size / canvas
    ctx.saveGState()
    ctx.scaleBy(x: s, y: s)

    // Plate.
    let plate = CGRect(x: plateInset, y: plateInset,
                       width: canvas - plateInset * 2,
                       height: canvas - plateInset * 2)
    let rounded = CGPath(roundedRect: plate,
                         cornerWidth: plateCorner, cornerHeight: plateCorner,
                         transform: nil)
    ctx.addPath(rounded)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fillPath()

    // Mark, centred in the plate.
    let markSize = plate.width * markScale
    let originX = plate.minX + (plate.width - markSize) / 2
    let originY = plate.minY + (plate.height - markSize) / 2

    // CoreGraphics is y-up and the geometry above is y-down, so flip once here
    // rather than inverting every coordinate.
    func p(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: originX + x * markSize, y: originY + (1 - y) * markSize)
    }

    let path = CGMutablePath()
    for segment in Mark.head {
        switch segment {
        case let .move(x, y): path.move(to: p(x, y))
        case let .line(x, y): path.addLine(to: p(x, y))
        case let .curve(to, c1, c2):
            path.addCurve(to: p(to.0, to.1), control1: p(c1.0, c1.1), control2: p(c2.0, c2.1))
        case .close: path.closeSubpath()
        }
    }
    ctx.addPath(path)
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    ctx.fillPath()

    // Waves.
    let centre = p(Mark.waveCentre.x, Mark.waveCentre.y)
    let waves = Mark.waves(atPixelSize: size)
    ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    ctx.setLineCap(.round)
    for radius in waves.radii {
        ctx.setLineWidth(waves.width * markSize)
        ctx.addArc(center: centre,
                   radius: radius * markSize,
                   startAngle: -Mark.waveSpread * .pi / 180,
                   endAngle: Mark.waveSpread * .pi / 180,
                   clockwise: false)
        ctx.strokePath()
    }

    ctx.restoreGState()
}

func png(size: Int) -> Data {
    let ctx = CGContext(data: nil, width: size, height: size,
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    drawIcon(into: ctx, size: Double(size))
    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])!
}

// MARK: - SVG

func svg() -> String {
    let markSize = (canvas - plateInset * 2) * markScale
    let originX = plateInset + (canvas - plateInset * 2 - markSize) / 2
    let originY = plateInset + (canvas - plateInset * 2 - markSize) / 2

    func f(_ v: Double) -> String { String(format: "%.2f", v) }
    func x(_ v: Double) -> String { f(originX + v * markSize) }
    func y(_ v: Double) -> String { f(originY + v * markSize) }

    var d = ""
    for segment in Mark.head {
        switch segment {
        case let .move(px, py): d += "M\(x(px)) \(y(py)) "
        case let .line(px, py): d += "L\(x(px)) \(y(py)) "
        case let .curve(to, c1, c2):
            d += "C\(x(c1.0)) \(y(c1.1)) \(x(c2.0)) \(y(c2.1)) \(x(to.0)) \(y(to.1)) "
        case .close: d += "Z"
        }
    }

    let cx = originX + Mark.waveCentre.x * markSize
    let cy = originY + Mark.waveCentre.y * markSize
    let spread = Mark.waveSpread * .pi / 180
    // The SVG is the large artwork — it is used at poster sizes on the website,
    // never at 16pt.
    let waves = Mark.waves(atPixelSize: 1024)
    let arcs = waves.radii.map { r -> String in
        let radius = r * markSize
        let x1 = cx + radius * cos(-spread), y1 = cy + radius * sin(-spread)
        let x2 = cx + radius * cos(spread), y2 = cy + radius * sin(spread)
        return """
              <path d="M\(f(x1)) \(f(y1)) A\(f(radius)) \(f(radius)) 0 0 1 \(f(x2)) \(f(y2))" \
        fill="none" stroke="#000" stroke-width="\(f(waves.width * markSize))" stroke-linecap="round"/>
        """
    }.joined(separator: "\n")

    let plateSize = canvas - plateInset * 2
    return """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(f(canvas)) \(f(canvas))">
      <rect x="\(f(plateInset))" y="\(f(plateInset))" width="\(f(plateSize))" height="\(f(plateSize))" \
    rx="\(f(plateCorner))" fill="#fff"/>
      <path d="\(d)" fill="#000"/>
    \(arcs)
    </svg>

    """
}

// MARK: - Main

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: icon.swift <output-directory>\n".utf8))
    exit(1)
}
let out = URL(fileURLWithPath: arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

try svg().write(to: out.appendingPathComponent("AppIcon.svg"), atomically: true, encoding: .utf8)

// Every size an .icns carries, at both scales.
let iconset = out.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try png(size: 1024).write(to: out.appendingPathComponent("AppIcon-preview.png"))
print("wrote AppIcon.svg, AppIcon.iconset, AppIcon-preview.png to \(out.path)")
