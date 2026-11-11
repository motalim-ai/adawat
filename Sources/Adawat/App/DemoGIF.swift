import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Draws the README's animated demo from the app's real wheel and toast: a photo is dragged, Shift is
/// pressed, the wheel opens, the pointer sweeps to WEBP, and the converted copy appears.
///
///   Adawat --demo-gif <out.gif> <photo>
@MainActor
enum DemoGIF {
    private static let canvas = CGSize(width: 880, height: 540)
    private static let fps = 25.0
    private static let wheelScale: CGFloat = 1.15
    private static let background = NSColor(srgbRed: 0.955, green: 0.95, blue: 0.985, alpha: 1)

    static func make(to output: URL, photo: URL) {
        guard let thumbnail = NSImage(contentsOf: photo) else {
            fputs("Could not read \(photo.path)\n", stderr)
            return
        }
        let name = photo.lastPathComponent
        let converted = photo.deletingPathExtension().appendingPathExtension("webp").lastPathComponent
        let model = WheelModel()
        model.mode = .convert
        model.operations = OperationCatalog.operations(for: .convert, files: [photo])
        model.fileCount = 1
        model.isVisible = true
        let count = model.operations.count
        let target = model.operations.firstIndex { $0.id == "image.webp" } ?? 2

        // Every hover state of the wheel, rendered once.
        var wheels: [Int: CGImage] = [:]
        for index in -1..<count {
            model.hoveredIndex = index < 0 ? nil : index
            wheels[index] = render(WheelView(model: model))
        }
        let toastModel = HUDModel()
        toastModel.text = L10n.t("Saved \(converted)")
        toastModel.style = .success
        // Padded so its shadow is not clipped into a gray box.
        let toast = render(HUDView(model: toastModel).fixedSize().padding(24).environment(\.layoutDirection, L10n.direction))

        let source = CGPoint(x: 150, y: 270), center = CGPoint(x: 520, y: 270)
        let wheelSize = WheelGeometry.size * wheelScale
        let wheelOrigin = CGPoint(x: center.x - wheelSize / 2, y: center.y - wheelSize / 2)
        func onWheel(_ index: Int, radius: CGFloat = 1.05) -> CGPoint {
            let angle = -Double.pi / 2 + Double(index) / Double(count) * 2 * Double.pi
            let r = WheelGeometry.labelRadius * radius * wheelScale
            return CGPoint(x: center.x + r * CGFloat(cos(angle)), y: center.y + r * CGFloat(sin(angle)))
        }
        func hovered(at point: CGPoint) -> Int? {
            WheelGeometry.index(at: CGPoint(x: (point.x - wheelOrigin.x) / wheelScale, y: (point.y - wheelOrigin.y) / wheelScale), count: count)
        }

        var frames: [CGImage] = []
        let total = 175
        for frame in 0..<total {
            let f = Double(frame)
            var cursor = source.offset(30, 26)
            var dragging = false
            var wheelAlpha = 0.0, wheelGrow = 1.0, keyAlpha = 0.0, toastAlpha = 0.0, resultAlpha = 0.0

            switch frame {
            case 0..<12:
                break
            case 12..<40:
                dragging = true
                cursor = lerp(source.offset(30, 26), center, ease(progress(f, 12, 40)))
            case 40..<52:
                dragging = true
                cursor = center
                keyAlpha = ease(progress(f, 40, 46))
                wheelAlpha = ease(progress(f, 44, 52))
                wheelGrow = 0.86 + 0.14 * wheelAlpha
            case 52..<112:
                dragging = true
                keyAlpha = 1
                wheelAlpha = 1
                // Out to the first petal, then around the ring to WEBP, where it rests.
                if f < 62 {
                    cursor = lerp(center, onWheel(0), ease(progress(f, 52, 62)))
                } else {
                    let step = ease(progress(f, 64, 96)) * Double(target)
                    let angle = -Double.pi / 2 + step / Double(count) * 2 * Double.pi
                    let r = WheelGeometry.labelRadius * 1.05 * wheelScale
                    cursor = CGPoint(x: center.x + r * CGFloat(cos(angle)), y: center.y + r * CGFloat(sin(angle)))
                }
            case 112..<122:
                cursor = onWheel(target)
                let t = ease(progress(f, 112, 122))
                wheelAlpha = 1 - t
                wheelGrow = 1 - 0.05 * t
                keyAlpha = 1 - t
            default:
                cursor = onWheel(target)
                resultAlpha = ease(progress(f, 122, 132))
                toastAlpha = frame < 160 ? ease(progress(f, 122, 128)) : 1 - ease(progress(f, 160, 170))
            }
            let hover = wheelAlpha > 0.5 ? hovered(at: cursor) : nil

            guard let image = draw({ ctx in
                ctx.setFillColor(background.cgColor)
                ctx.fill(CGRect(origin: .zero, size: canvas))
                fileIcon(thumbnail, name: name, at: source, alpha: 1, in: ctx)
                if resultAlpha > 0 {
                    fileIcon(thumbnail, name: converted, at: source.offset(0, 150), alpha: resultAlpha,
                             scale: 0.8 + 0.2 * resultAlpha, in: ctx)
                }
                if wheelAlpha > 0, let wheel = wheels[hover ?? -1] {
                    let size = wheelSize * wheelGrow
                    ctx.setAlpha(wheelAlpha)
                    drawImage(wheel, in: CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size), ctx)
                    ctx.setAlpha(1)
                }
                if keyAlpha > 0 { keycap("⇧  Shift", at: CGPoint(x: center.x, y: canvas.height - 44), alpha: keyAlpha, in: ctx) }
                // The drag image trails below-right of the pointer, as Finder's does, so the petal stays visible.
                if dragging { fileIcon(thumbnail, name: nil, at: cursor.offset(8 - 96 * 0.19, 14 - 72 * 0.19), alpha: 0.8, scale: 0.62, in: ctx) }
                if toastAlpha > 0, let toast {
                    let size = CGSize(width: CGFloat(toast.width) / 2, height: CGFloat(toast.height) / 2)
                    ctx.setAlpha(toastAlpha)
                    drawImage(toast, in: CGRect(x: (canvas.width - size.width) / 2, y: CGFloat(-2 - 8 * (1 - toastAlpha)),
                                                width: size.width, height: size.height), ctx)
                    ctx.setAlpha(1)
                }
                pointer(at: cursor, in: ctx)
            }) else { continue }
            frames.append(image)
        }
        write(frames, to: output)
    }

    // MARK: Drawing

    private static func render<V: View>(_ view: V) -> CGImage? {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .light))
        renderer.scale = 2
        return renderer.cgImage
    }

    /// A canvas with the origin at the top left, as SwiftUI and the wheel geometry use.
    private static func draw(_ body: (CGContext) -> Void) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: canvas.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        body(ctx)
        NSGraphicsContext.current = previous
        return ctx.makeImage()
    }

    private static func drawImage(_ image: CGImage, in rect: CGRect, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    /// A Finder-style photo icon: the picture in a white frame with its name below. `at` is its top left.
    private static func fileIcon(_ image: NSImage, name: String?, at origin: CGPoint, alpha: CGFloat, scale: CGFloat = 1,
                                 in ctx: CGContext) {
        let size = CGSize(width: 96 * scale, height: 72 * scale)
        let frame = CGRect(x: origin.x + (96 - size.width) / 2, y: origin.y + (72 - size.height) / 2, width: size.width, height: size.height)
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.setShadow(offset: CGSize(width: 0, height: 3), blur: 8, color: NSColor.black.withAlphaComponent(0.18).cgColor)
        ctx.setFillColor(.white)
        ctx.addPath(CGPath(roundedRect: frame, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0)
        let photo = frame.insetBy(dx: 4, dy: 4)
        ctx.addPath(CGPath(roundedRect: photo, cornerWidth: 3, cornerHeight: 3, transform: nil))
        ctx.clip()
        image.draw(in: aspectFill(image.size, in: photo), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        ctx.restoreGState()
        if let name {
            let text = NSAttributedString(string: name, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor(white: 0.15, alpha: alpha),
            ])
            let width = text.size().width
            text.draw(at: CGPoint(x: origin.x + 48 - width / 2, y: origin.y + 80))
        }
    }

    private static func keycap(_ label: String, at center: CGPoint, alpha: CGFloat, in ctx: CGContext) {
        let text = NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor(white: 0.16, alpha: 1),
        ])
        let size = text.size()
        let rect = CGRect(x: center.x - size.width / 2 - 18, y: center.y - 18, width: size.width + 36, height: 36)
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 6, color: NSColor.black.withAlphaComponent(0.15).cgColor)
        ctx.setFillColor(.white)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 9, cornerHeight: 9, transform: nil))
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0)
        ctx.setStrokeColor(NSColor(srgbRed: 0.36, green: 0.28, blue: 0.9, alpha: 0.9).cgColor)
        ctx.setLineWidth(1.5)
        ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), cornerWidth: 9, cornerHeight: 9, transform: nil))
        ctx.strokePath()
        text.draw(at: CGPoint(x: rect.minX + 18, y: rect.midY - size.height / 2))
        ctx.restoreGState()
    }

    /// The standard arrow pointer with its hot spot at `point`.
    private static func pointer(at point: CGPoint, in ctx: CGContext) {
        let cursor = NSCursor.arrow
        let image = cursor.image
        let rect = CGRect(x: point.x - cursor.hotSpot.x, y: point.y - cursor.hotSpot.y, width: image.size.width, height: image.size.height)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private static func aspectFill(_ size: CGSize, in rect: CGRect) -> CGRect {
        let scale = max(rect.width / max(size.width, 1), rect.height / max(size.height, 1))
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
    }

    // MARK: Timing and output

    private static func progress(_ frame: Double, _ start: Double, _ end: Double) -> Double {
        min(1, max(0, (frame - start) / (end - start)))
    }

    private static func ease(_ t: Double) -> Double { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }

    private static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    private static func write(_ frames: [CGImage], to output: URL) {
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else { return }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for (index, frame) in frames.enumerated() {
            // Hold the last frame a little before the loop starts again.
            let delay = index == frames.count - 1 ? 1.2 : 1 / fps
            CGImageDestinationAddImage(destination, frame, [kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay,
            ]] as CFDictionary)
        }
        if CGImageDestinationFinalize(destination) { print(output.path) }
    }
}

private extension CGPoint {
    func offset(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint { CGPoint(x: x + dx, y: y + dy) }
}
