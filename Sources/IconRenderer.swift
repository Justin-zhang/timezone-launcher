import AppKit

enum IconRenderer {
    static let canvas: CGFloat = 1024

    /// 目标 App 图标右下角叠一个圆形角标
    static func badgedIcon(base: NSImage, badge: String, color: NSColor, size: CGFloat = canvas) -> NSBitmapImageRep {
        draw(size: size) { s in
            base.draw(in: NSRect(x: 0, y: 0, width: s, height: s), from: .zero, operation: .sourceOver, fraction: 1)

            let d = s * 0.42
            let m = s * 0.02
            let circle = NSRect(x: s - d - m, y: m, width: d, height: d)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: circle.insetBy(dx: -s * 0.018, dy: -s * 0.018)).fill()
            color.setFill()
            NSBezierPath(ovalIn: circle).fill()

            drawCentered(badge, in: circle, maxWidth: d * 0.78, startSize: d * 0.67, color: .white)
        }
    }

    /// 时区启动器自身和快捷方式文件夹用的图标:红色圆角方块 + 表盘 + 一个字
    static func clockIcon(text: String, size: CGFloat = canvas) -> NSBitmapImageRep {
        draw(size: size) { s in
            let k = s / canvas
            let body = NSRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
            let shape = NSBezierPath(roundedRect: body, xRadius: 185 * k, yRadius: 185 * k)

            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
            shadow.shadowBlurRadius = 28 * k
            shadow.shadowOffset = NSSize(width: 0, height: -12 * k)
            shadow.set()
            NSColor.black.setFill()
            shape.fill()
            NSGraphicsContext.restoreGraphicsState()

            NSGradient(starting: NSColor(srgbRed: 0.95, green: 0.33, blue: 0.27, alpha: 1),
                       ending: NSColor(srgbRed: 0.72, green: 0.07, blue: 0.10, alpha: 1))!
                .draw(in: shape, angle: -90)

            let c = NSPoint(x: body.midX, y: body.midY)
            let r = 300 * k
            NSColor.white.withAlphaComponent(0.30).setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            ring.lineWidth = 22 * k
            ring.stroke()
            for i in 0..<12 {
                let a = CGFloat(i) * .pi / 6
                let len = (i % 3 == 0 ? 52 : 28) * k
                let tick = NSBezierPath()
                tick.move(to: NSPoint(x: c.x + cos(a) * (r - 30 * k), y: c.y + sin(a) * (r - 30 * k)))
                tick.line(to: NSPoint(x: c.x + cos(a) * (r - 30 * k - len), y: c.y + sin(a) * (r - 30 * k - len)))
                tick.lineWidth = (i % 3 == 0 ? 16 : 10) * k
                tick.lineCapStyle = .round
                tick.stroke()
            }

            let box = NSRect(x: c.x - r, y: c.y - r + 8 * k, width: r * 2, height: r * 2)
            drawCentered(text, in: box, maxWidth: r * 1.3, startSize: 330 * k, color: .white)
        }
    }

    static func image(_ rep: NSBitmapImageRep) -> NSImage {
        let img = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
        img.addRepresentation(rep)
        return img
    }

    static func pngData(_ rep: NSBitmapImageRep, pixels: Int? = nil) -> Data? {
        let target = pixels.map { scaled(rep, to: $0) } ?? rep
        return target.representation(using: .png, properties: [:])
    }

    /// 生成 .icns(借助系统自带的 iconutil)
    static func writeICNS(_ rep: NSBitmapImageRep, to url: URL) throws {
        let fm = FileManager.default
        let iconset = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".iconset")
        try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: iconset) }
        for s in [16, 32, 128, 256, 512] {
            for (scale, suffix) in [(1, ""), (2, "@2x")] {
                guard let data = pngData(rep, pixels: s * scale) else { throw BuildError.icon("PNG 编码失败") }
                try data.write(to: iconset.appendingPathComponent("icon_\(s)x\(s)\(suffix).png"))
            }
        }
        let r = try Shell.run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", url.path])
        guard r.status == 0 else { throw BuildError.icon("iconutil 失败:" + r.errText) }
    }

    // MARK: - 内部

    private static func draw(size: CGFloat, _ body: (CGFloat) -> Void) -> NSBitmapImageRep {
        let px = Int(size)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: rep)
        ctx?.imageInterpolation = .high
        NSGraphicsContext.current = ctx
        body(size)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func scaled(_ rep: NSBitmapImageRep, to px: Int) -> NSBitmapImageRep {
        draw(size: CGFloat(px)) { s in
            rep.draw(in: NSRect(x: 0, y: 0, width: s, height: s), from: .zero, operation: .copy,
                     fraction: 1, respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        }
    }

    /// 在矩形中居中画字,超宽时逐步缩小字号
    private static func drawCentered(_ text: String, in rect: NSRect, maxWidth: CGFloat, startSize: CGFloat, color: NSColor) {
        guard !text.isEmpty else { return }
        let str = text as NSString
        var fontSize = startSize
        var attrs: [NSAttributedString.Key: Any] = [:]
        var ts = NSSize.zero
        repeat {
            attrs = [.font: NSFont.systemFont(ofSize: fontSize, weight: .heavy), .foregroundColor: color]
            ts = str.size(withAttributes: attrs)
            fontSize *= 0.92
        } while ts.width > maxWidth && fontSize > 8
        str.draw(at: NSPoint(x: rect.midX - ts.width / 2, y: rect.midY - ts.height / 2), withAttributes: attrs)
    }
}
