// Zeichnet das App-Icon von Flow: gestapelte Karten, darauf ein farbiges 3×3-Raster mit Play-Zeichen.
// Aufruf: swift Tools/make-icon.swift <Ausgabeordner.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func linear(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

let edgeWidth: CGFloat = 18

func card(_ ctx: CGContext, _ rect: CGRect, radius: CGFloat, edge: [CGColor]) {
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 24, color: color(0x000000, 0.22))
    ctx.addPath(path); ctx.setFillColor(color(0xFFFFFF)); ctx.fillPath()
    ctx.restoreGState()
    // Weißer Rand, rundum gleich breit, darin die farbige Fläche.
    let body = rect.insetBy(dx: edgeWidth, dy: edgeWidth)
    let inner = radius - edgeWidth
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: inner, cornerHeight: inner, transform: nil)); ctx.clip()
    linear(ctx, edge, from: CGPoint(x: rect.minX, y: 0), to: CGPoint(x: rect.maxX, y: 0))
    ctx.restoreGState()
}

func draw(_ ctx: CGContext) {
    // Oben links als Ursprung, wie in einem Layout.
    ctx.translateBy(x: 0, y: 1024); ctx.scaleBy(x: 1, y: -1)

    card(ctx, CGRect(x: 170, y: 96, width: 684, height: 400), radius: 96, edge: [color(0x8BD13F), color(0x2FA8E0)])
    card(ctx, CGRect(x: 132, y: 150, width: 760, height: 400), radius: 104, edge: [color(0xF0564A), color(0xF7C63A)])

    // Vordere Karte.
    let front = CGRect(x: 72, y: 214, width: 880, height: 720)
    let frontPath = CGPath(roundedRect: front, cornerWidth: 124, cornerHeight: 124, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 16), blur: 36, color: color(0x000000, 0.28))
    ctx.addPath(frontPath); ctx.setFillColor(color(0xFFFFFF)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: front.insetBy(dx: 18, dy: 18), cornerWidth: 106, cornerHeight: 106, transform: nil))
    ctx.clip()
    linear(ctx, [color(0xFBFBFC), color(0xEDEEF1)], from: CGPoint(x: 0, y: front.minY), to: CGPoint(x: 0, y: front.maxY))
    ctx.restoreGState()

    // 3×3-Raster in Spektralfarben.
    let tiles: [(UInt32, UInt32)] = [
        (0xFF6B6B, 0xF2445A), (0xFFA94D, 0xF7792B), (0xFFD84D, 0xF5B82E),
        (0xE36FB8, 0xC9459B), (0x5B8CFF, 0x3A63E8), (0x8EDB5A, 0x5BBF3A),
        (0x9C7BF0, 0x7553D9), (0x4CB7F5, 0x2391E0), (0x47D1B6, 0x24B394),
    ]
    let side: CGFloat = 150, gap: CGFloat = 26
    let total = side * 3 + gap * 2
    let origin = CGPoint(x: front.midX - total / 2, y: front.midY - total / 2)
    for (i, tile) in tiles.enumerated() {
        let r = CGRect(x: origin.x + CGFloat(i % 3) * (side + gap), y: origin.y + CGFloat(i / 3) * (side + gap),
                       width: side, height: side)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 4), blur: 10, color: color(0x000000, 0.12))
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 50, cornerHeight: 50, transform: nil))
        ctx.setFillColor(color(tile.1)); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 50, cornerHeight: 50, transform: nil)); ctx.clip()
        linear(ctx, [color(tile.0), color(tile.1)], from: CGPoint(x: r.minX, y: r.minY), to: CGPoint(x: r.maxX, y: r.maxY))
        ctx.restoreGState()
    }

    // Play-Zeichen auf der mittleren Kachel.
    // Optisch mittig: zwischen Mitte des Rahmens und Schwerpunkt des Dreiecks.
    let center = CGPoint(x: front.midX, y: front.midY)
    let play = CGMutablePath()
    play.move(to: CGPoint(x: center.x - 31, y: center.y - 42))
    play.addLine(to: CGPoint(x: center.x + 43, y: center.y))
    play.addLine(to: CGPoint(x: center.x - 31, y: center.y + 42))
    play.closeSubpath()
    ctx.addPath(play)
    ctx.setLineJoin(.round); ctx.setLineWidth(14)
    ctx.setFillColor(color(0xFFFFFF)); ctx.setStrokeColor(color(0xFFFFFF))
    ctx.drawPath(using: .fillStroke)
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
        ctx.interpolationQuality = .high
        draw(ctx)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
    }
}
