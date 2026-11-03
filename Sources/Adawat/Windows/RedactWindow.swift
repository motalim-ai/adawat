import AppKit
import CoreImage
import SwiftUI
import Vision

enum RedactStyle: String, CaseIterable, Identifiable {
    case solid = "Solid", blur = "Blur"
    var id: String { rawValue }
}

struct RedactBox: Identifiable, Equatable {
    let id = UUID()
    /// Normalized, top-left origin.
    var rect: CGRect
}

enum Redactor {
    /// Covers every box: a flat color, or a pixelated blur strong enough that detail cannot be read back.
    static func apply(_ boxes: [RedactBox], style: RedactStyle, color: RGB, to image: CIImage) -> CIImage {
        let extent = image.extent
        var output = image
        for box in boxes {
            let r = box.rect
            let pixels = CGRect(x: extent.minX + r.minX * extent.width, y: extent.minY + (1 - r.maxY) * extent.height,
                                width: r.width * extent.width, height: r.height * extent.height).integral
            guard pixels.width >= 1, pixels.height >= 1 else { continue }
            let cover: CIImage
            switch style {
            case .solid:
                cover = CIImage(color: CIColor(red: color.red, green: color.green, blue: color.blue)).cropped(to: pixels)
            case .blur:
                let block = max(6, max(pixels.width, pixels.height) / 10)
                cover = image.clampedToExtent()
                    .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: block,
                                                                kCIInputCenterKey: CIVector(x: pixels.midX, y: pixels.midY)])
                    .applyingGaussianBlur(sigma: block * 0.6)
                    .cropped(to: pixels)
            }
            output = cover.composited(over: output)
        }
        return output.cropped(to: extent)
    }

    /// Faces or text found on the device, as normalized top-left boxes with a little margin.
    static func detect(faces: Bool, in image: CGImage) async -> [CGRect] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request: VNImageBasedRequest
                if faces {
                    request = VNDetectFaceRectanglesRequest()
                } else {
                    let text = VNRecognizeTextRequest()
                    text.recognitionLevel = .fast
                    text.automaticallyDetectsLanguage = true
                    request = text
                }
                try? VNImageRequestHandler(cgImage: image).perform([request])
                let boxes = (request.results as? [VNDetectedObjectObservation] ?? []).map { observation -> CGRect in
                    let b = observation.boundingBox
                    let margin = faces ? 0.18 : 0.08
                    return CGRect(x: b.minX - b.width * margin, y: 1 - b.maxY - b.height * margin,
                                  width: b.width * (1 + margin * 2), height: b.height * (1 + margin * 2))
                        .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                }
                continuation.resume(returning: boxes)
            }
        }
    }
}

@MainActor
final class RedactModel: ObservableObject {
    let file: URL
    let source: CGImage
    @Published var boxes: [RedactBox] = []
    @Published var style: RedactStyle = .solid
    @Published var color = Color.black
    @Published var selection: UUID?
    @Published var preview: CGImage?
    @Published var status: String?

    private var drag: (index: Int, original: CGRect, mode: DragMode)?
    private enum DragMode { case move, resize(corner: Int), create(start: CGPoint) }

    init(file: URL) throws {
        self.file = file
        source = try ImageFile(file).upright(maxPixels: 1400)
        preview = source
    }

    var rgb: RGB { RGB(NSColor(color).cgColor) }

    func render() async {
        try? await Task.sleep(nanoseconds: 20_000_000)
        guard !Task.isCancelled else { return }
        let output = Redactor.apply(boxes, style: style, color: rgb, to: CIImage(cgImage: source))
        preview = ImageEngine.ciContext.createCGImage(output, from: CGRect(x: 0, y: 0, width: source.width, height: source.height))
    }

    var renderKey: String { "\(boxes.map(\.rect))\(style)\(color)" }

    private func clamp(_ p: CGPoint) -> CGPoint { CGPoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1)) }

    func dragChanged(start: CGPoint, current: CGPoint) {
        let start = clamp(start), current = clamp(current)
        if drag == nil {
            if let selected = boxes.firstIndex(where: { $0.id == selection }),
               let corner = corner(of: boxes[selected].rect, near: start) {
                drag = (selected, boxes[selected].rect, .resize(corner: corner))
            } else if let index = boxes.lastIndex(where: { $0.rect.contains(start) }) {
                drag = (index, boxes[index].rect, .move)
                selection = boxes[index].id
            } else {
                boxes.append(RedactBox(rect: CGRect(origin: start, size: .zero)))
                selection = boxes.last?.id
                drag = (boxes.count - 1, .zero, .create(start: start))
            }
        }
        guard let drag else { return }
        let dx = current.x - start.x, dy = current.y - start.y
        switch drag.mode {
        case .move:
            var r = drag.original.offsetBy(dx: dx, dy: dy)
            r.origin.x = min(max(r.minX, 0), 1 - r.width)
            r.origin.y = min(max(r.minY, 0), 1 - r.height)
            boxes[drag.index].rect = r
        case .create(let origin):
            boxes[drag.index].rect = CGRect(x: min(origin.x, current.x), y: min(origin.y, current.y),
                                            width: abs(current.x - origin.x), height: abs(current.y - origin.y))
        case .resize(let corner):
            var minX = drag.original.minX, maxX = drag.original.maxX, minY = drag.original.minY, maxY = drag.original.maxY
            if corner % 2 == 0 { minX = min(minX + dx, maxX - 0.01) } else { maxX = max(maxX + dx, minX + 0.01) }
            if corner < 2 { minY = min(minY + dy, maxY - 0.01) } else { maxY = max(maxY + dy, minY + 0.01) }
            boxes[drag.index].rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }

    func dragEnded() {
        if let drag, case .create = drag.mode, boxes[drag.index].rect.width < 0.01 || boxes[drag.index].rect.height < 0.01 {
            boxes.remove(at: drag.index)
            selection = nil
        }
        drag = nil
    }

    /// Corners: 0 top-left, 1 top-right, 2 bottom-left, 3 bottom-right.
    private func corner(of rect: CGRect, near point: CGPoint) -> Int? {
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
        return corners.firstIndex { hypot($0.x - point.x, $0.y - point.y) < 0.025 }
    }

    func deleteSelected() {
        boxes.removeAll { $0.id == selection }
        selection = nil
    }

    func detect(faces: Bool) async {
        status = faces ? "Detecting faces…" : "Detecting text…"
        let found = await Redactor.detect(faces: faces, in: source)
        boxes += found.map { RedactBox(rect: $0) }
        status = found.isEmpty ? (faces ? "No faces found" : "No text found")
            : "Covered \(found.count) \(faces ? (found.count == 1 ? "face" : "faces") : "text area\(found.count == 1 ? "" : "s")")"
    }
}

struct RedactView: View {
    @ObservedObject var model: RedactModel
    let handle: ToolWindowHandle

    private var displaySize: CGSize {
        let scale = min(480 / CGFloat(model.source.width), 420 / CGFloat(model.source.height))
        return CGSize(width: CGFloat(model.source.width) * scale, height: CGFloat(model.source.height) * scale)
    }

    var body: some View {
        ToolScaffold(title: L10n.t("Redact Photo"), onClose: handle.close) {
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(white: 0.1))
                    canvas
                }
                .frame(height: displaySize.height + 24)
                ToolRow(title: L10n.t("Style")) {
                    Picker("", selection: $model.style) {
                        ForEach(RedactStyle.allCases) { Text(L10n.t($0.rawValue)).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                if model.style == .solid {
                    ToolRow(title: L10n.t("Color")) { ColorPicker("", selection: $model.color, supportsOpacity: false).labelsHidden() }
                } else {
                    Text(L10n.t("Blur softens details. Use Solid for sensitive information."))
                        .font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                ToolRow(title: L10n.t("Detect")) {
                    HStack(spacing: 6) {
                        Button(L10n.t("Faces")) { Task { await model.detect(faces: true) } }.buttonStyle(.tool)
                        Button(L10n.t("Text")) { Task { await model.detect(faces: false) } }.buttonStyle(.tool)
                    }
                }
                HStack {
                    Text(model.status ?? "Draw rectangles over the areas to hide. Drag a box to move it, or its corners to resize.")
                        .font(.system(size: 11)).foregroundStyle(Theme.muted)
                    Spacer()
                    Button(action: model.deleteSelected) { Image(systemName: "trash") }
                        .buttonStyle(.tool).disabled(model.selection == nil).keyboardShortcut(.delete, modifiers: [])
                        .help(L10n.t("Delete Redaction"))
                }
            }
        } leading: {
            Button(L10n.t("Reset")) { model.boxes = []; model.selection = nil; model.status = nil }
                .buttonStyle(.tool).disabled(model.boxes.isEmpty)
        } trailing: {
            Button(L10n.t("Save Redacted Copy"), action: save).buttonStyle(.tool).keyboardShortcut(.defaultAction)
                .disabled(model.boxes.isEmpty)
        }
        .task(id: model.renderKey) { await model.render() }
    }

    private var canvas: some View {
        let size = displaySize
        return ZStack(alignment: .topLeading) {
            if let preview = model.preview {
                Image(decorative: preview, scale: 1).resizable().frame(width: size.width, height: size.height)
            }
            ForEach(model.boxes) { box in
                let r = CGRect(x: box.rect.minX * size.width, y: box.rect.minY * size.height,
                               width: box.rect.width * size.width, height: box.rect.height * size.height)
                let selected = box.id == model.selection
                Rectangle().strokeBorder(selected ? Theme.accent : Color.white.opacity(0.5), lineWidth: selected ? 2 : 1)
                    .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
                    .allowsHitTesting(false)
                if selected {
                    ForEach(0..<4, id: \.self) { corner in
                        RoundedRectangle(cornerRadius: 2).fill(Theme.accent).frame(width: 9, height: 9)
                            .position(x: corner % 2 == 0 ? r.minX : r.maxX, y: corner < 2 ? r.minY : r.maxY)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { value in
                model.dragChanged(start: CGPoint(x: value.startLocation.x / size.width, y: value.startLocation.y / size.height),
                                  current: CGPoint(x: value.location.x / size.width, y: value.location.y / size.height))
            }
            .onEnded { _ in model.dragEnded() })
        .clipped()
        .environment(\.layoutDirection, .leftToRight)
    }

    private func save() {
        let (boxes, style, color, file) = (model.boxes, model.style, model.rgb, model.file)
        handle.close()
        OperationRunner.run("Redact", on: [file]) { files, context in
            context.report("Saving redacted copy")
            let url = files[0]
            let format = ImageEngine.editedFormat(for: url)
            let out = Output.url(for: url, extension: format.ext, suffix: "redacted")
            // Location and camera data could identify the scene too, so the redacted copy carries none.
            try await ImageEngine.saveFiltered(try ImageFile(url), as: format, to: out, quality: 0.92) {
                Redactor.apply(boxes, style: style, color: color, to: $0)
            }
            let clean = Output.temporaryURL(extension: format.ext)
            let written = try await ImageEngine.stripMetadata(try ImageFile(out), to: clean)
            _ = try FileManager.default.replaceItemAt(out, withItemAt: written)
            return [out]
        }
    }
}

@MainActor
enum RedactWindow {
    static func open(_ files: [URL]) { open(files, show: true) }

    @discardableResult
    static func open(_ files: [URL], show: Bool, sample: Bool = false) -> NSWindow? {
        guard let file = files.first else { return nil }
        do {
            let model = try RedactModel(file: file)
            if sample {
                model.boxes = [RedactBox(rect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.2)),
                               RedactBox(rect: CGRect(x: 0.55, y: 0.5, width: 0.3, height: 0.3))]
                model.selection = model.boxes[1].id
                model.style = .blur
            }
            return ToolWindows.present(L10n.t("Redact Photo"), width: 520, show: show) { handle in
                RedactView(model: model, handle: handle)
            }
        } catch {
            HUDController.shared.show(error.localizedDescription, style: .failure)
            return nil
        }
    }
}
