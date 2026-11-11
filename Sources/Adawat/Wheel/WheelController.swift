import AppKit
import SwiftUI

@MainActor
final class WheelModel: ObservableObject {
    @Published var mode: WheelMode = .convert
    @Published var operations: [AdawatOperation] = []
    @Published var hoveredIndex: Int?
    @Published var fileCount = 0
    @Published var isVisible = false

    var hoveredOperation: AdawatOperation? {
        hoveredIndex.flatMap { operations.indices.contains($0) ? operations[$0] : nil }
    }
}

enum WheelGeometry {
    static let size: CGFloat = 300
    static let outerRadius: CGFloat = 119.5
    static let innerRadius: CGFloat = 48.6
    static var labelRadius: CGFloat { (innerRadius + outerRadius) / 2 }

    /// Center of petal `index` of `count`, starting at the top and going clockwise.
    static func position(index: Int, count: Int) -> CGPoint {
        let angle = -Double.pi / 2 + Double(index) / Double(max(count, 1)) * 2 * Double.pi
        return CGPoint(x: size / 2 + labelRadius * CGFloat(cos(angle)), y: size / 2 + labelRadius * CGFloat(sin(angle)))
    }

    /// The petal under `point` (top-left origin), or nil over the center label.
    static func index(at point: CGPoint, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let dx = point.x - size / 2
        let dy = point.y - size / 2
        guard hypot(dx, dy) > innerRadius - 8 else { return nil }
        var angle = atan2(dy, dx) + Double.pi / 2
        if angle < 0 { angle += 2 * Double.pi }
        let step = 2 * Double.pi / Double(count)
        return Int((angle + step / 2) / step) % count
    }
}

@MainActor
final class WheelController {
    static let shared = WheelController()

    private let model = WheelModel()
    private var panel: NSPanel?
    private var files: [URL] = []
    private var didDrop = false
    /// Tracked here rather than read from the panel, so an interrupted fade-out
    /// can never leave a transparent wheel that blocks the next show.
    private var isShown = false

    func show(mode: WheelMode, files: [URL], at location: NSPoint) {
        self.files = files
        didDrop = false
        model.mode = mode
        model.fileCount = files.count
        model.operations = OperationCatalog.operations(for: mode, files: files)
        model.hoveredIndex = nil

        let panel = self.panel ?? makePanel()
        self.panel = panel

        // Re-centering only on first show keeps the wheel still while switching modes.
        if !isShown {
            panel.setFrame(frame(centeredAt: location), display: false)
            panel.alphaValue = 0
        }
        isShown = true
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
        model.isVisible = true
        DebugLog.write("wheel shown: \(mode.title), \(model.operations.count) choices")
        NotificationCenter.default.post(name: .adawatWheelShown, object: nil)
        Feedback.tick()
    }

    func dragDidEnd() {
        // The drop callback runs before the mouse-up is polled, so a short delay is enough.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            // Skip if a new drag already reopened the wheel.
            if NSEvent.pressedMouseButtons & 1 == 0 { self?.hide() }
        }
    }

    func hide() {
        guard let panel, isShown else { return }
        isShown = false
        model.isVisible = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                // A show that arrived during the fade keeps the panel on screen.
                if !self.isShown { panel.orderOut(nil) }
            }
        })
        DebugLog.write("wheel hidden")
    }

    fileprivate var isHoveringChoice: Bool { model.hoveredOperation != nil }

    func previewHover(index: Int) {
        model.hoveredIndex = index
    }

    fileprivate func updateHover(_ point: CGPoint?) {
        let index = point.flatMap { WheelGeometry.index(at: $0, count: model.operations.count) }
        if index != model.hoveredIndex {
            model.hoveredIndex = index
            if index != nil { Feedback.tick() }
        }
    }

    fileprivate func performDrop(files dropped: [URL]) -> Bool {
        guard let operation = model.hoveredOperation else { return false }
        didDrop = true
        let targets = dropped.isEmpty ? files : dropped
        hide()
        // Start after the drag session has fully ended, so panels the operation opens can take focus.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if let window = operation.window {
                window(targets)
            } else {
                OperationRunner.run(operation, on: targets)
            }
        }
        return true
    }

    private func frame(centeredAt point: NSPoint) -> NSRect {
        let size = WheelGeometry.size
        var rect = NSRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
            let visible = screen.visibleFrame
            rect.origin.x = min(max(rect.minX, visible.minX), visible.maxX - size)
            rect.origin.y = min(max(rect.minY, visible.minY), visible.maxY - size)
        }
        return rect
    }

    private func makePanel() -> NSPanel {
        let size = WheelGeometry.size
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        let hosting = NSHostingView(rootView: WheelView(model: model))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)

        // The drop target sits above the SwiftUI view so it receives every drag event.
        let dropView = WheelDropView(frame: container.bounds)
        dropView.autoresizingMask = [.width, .height]
        dropView.controller = self
        container.addSubview(dropView)

        panel.contentView = container
        return panel
    }
}

private final class WheelDropView: NSView {
    weak var controller: WheelController?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        track(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        track(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        MainActor.assumeIsolated { controller?.updateHover(nil) }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        return MainActor.assumeIsolated { controller?.performDrop(files: urls) ?? false }
    }

    private func track(_ sender: NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        let hovering = MainActor.assumeIsolated { () -> Bool in
            controller?.updateHover(point)
            return controller?.isHoveringChoice ?? false
        }
        guard hovering else { return [] }
        // Adawat only reads the files, so prefer copy; fall back to whatever the source allows
        // (Finder offers only "move" while ⌘ is held, which is the default tools key).
        let allowed = sender.draggingSourceOperationMask
        for operation: NSDragOperation in [.copy, .generic, .link, .move] where allowed.contains(operation) {
            return operation
        }
        return []
    }
}
