// Gera o AppIcon.iconset do Rosen: xcrun swift Scripts/make-icon.swift <saida.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.removeItem(at: out)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let s = CGFloat(pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Grade de ícones do macOS: conteúdo em ~80% do quadro.
    let inset = s * 0.098
    let rect = CGRect(x: inset, y: inset * 1.15, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.225
    let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Sombra
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(shape)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    let space = CGColorSpaceCreateDeviceRGB()
    func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a).cgColor
    }

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()

    // Espaço profundo: índigo escuro em cima, violeta embaixo.
    let sky = CGGradient(colorsSpace: space,
                         colors: [rgb(0.06, 0.06, 0.18), rgb(0.16, 0.10, 0.42), rgb(0.33, 0.20, 0.78)] as CFArray,
                         locations: [0, 0.6, 1])!
    ctx.drawLinearGradient(sky, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])

    // Estrelas (posições fixas, para o ícone ser sempre igual).
    if pixels >= 64 {
        let stars: [(CGFloat, CGFloat, CGFloat)] = [
            (0.16, 0.82, 1.0), (0.30, 0.90, 0.6), (0.78, 0.86, 0.9), (0.88, 0.70, 0.5),
            (0.12, 0.55, 0.5), (0.86, 0.36, 0.7), (0.22, 0.24, 0.6), (0.70, 0.14, 0.5),
        ]
        for (x, y, k) in stars {
            let r = s * 0.006 * k + 0.5
            ctx.setFillColor(rgb(1, 1, 1, 0.55 * k))
            ctx.fillEllipse(in: CGRect(x: rect.minX + rect.width * x - r, y: rect.minY + rect.height * y - r, width: r * 2, height: r * 2))
        }
    }

    // O buraco de minhoca: anéis que afunilam até um núcleo, vistos levemente de cima.
    let throat = CGPoint(x: rect.midX, y: rect.midY - rect.height * 0.13)
    let rings = 9
    for i in (0..<rings).reversed() {
        let t = CGFloat(i) / CGFloat(rings - 1)          // 0 = borda, 1 = garganta
        let w = rect.width * (0.86 - 0.74 * pow(t, 0.8))
        let h = w * (0.40 + 0.10 * t)
        let cy = throat.y + rect.height * 0.30 * pow(1 - t, 1.4) // a boca fica em cima; o fundo afunda
        let ring = CGRect(x: throat.x - w / 2, y: cy - h / 2, width: w, height: h)
        let alpha = 0.22 + 0.6 * t
        let color = t < 0.5 ? rgb(0.55, 0.50, 1.0, alpha) : rgb(0.45, 0.88, 1.0, alpha)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(max(1, s * (0.012 - 0.006 * t)))
        ctx.strokeEllipse(in: ring)
    }

    // Núcleo luminoso no fundo do túnel.
    let glow = CGGradient(colorsSpace: space,
                          colors: [rgb(1, 1, 1, 1), rgb(0.55, 0.92, 1.0, 0.85), rgb(0.40, 0.45, 1.0, 0)] as CFArray,
                          locations: [0, 0.25, 1])!
    ctx.drawRadialGradient(glow, startCenter: throat, startRadius: 0, endCenter: throat,
                           endRadius: rect.width * 0.15, options: [])

    // Brilho de vidro no topo.
    let shine = CGGradient(colorsSpace: space,
                           colors: [rgb(1, 1, 1, 0.14), rgb(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(shine, start: CGPoint(x: rect.midX, y: rect.maxY),
                           end: CGPoint(x: rect.midX, y: rect.midY + rect.height * 0.1), options: [])
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(pixels: base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(pixels: base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print("ok")
