import AppKit
import SwiftUI

@MainActor
final class HUDModel: ObservableObject {
    enum Style { case working, success, failure, cancelled }

    @Published var text = ""
    @Published var style: Style = .working
    @Published var progress: Double?
    /// What the Cancel button stops; nil hides the button.
    @Published var onCancel: (() -> Void)?
    /// The Cancel button's frame in the toast's panel, measured from its top left corner.
    var cancelFrame = CGRect.zero

    func cancel() {
        let action = onCancel
        onCancel = nil
        action?()
    }
}

/// A small toast at the top of the screen that reports what Adawat is doing. Clicks pass through it, except on the
/// Cancel button it offers for the work in progress.
@MainActor
final class HUDController {
    static let shared = HUDController()

    private let model = HUDModel()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private var pointerTimer: Timer?

    /// `cancel`, for work in progress, adds a Cancel button that calls it.
    func show(_ text: String, style: HUDModel.Style, cancel: (() -> Void)? = nil) {
        model.text = L10n.t(text)
        model.style = style
        model.progress = nil
        model.onCancel = style == .working ? cancel : nil
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }

        watchPointer(model.onCancel != nil)
        hideWork?.cancel()
        guard style != .working else { return }
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (style == .failure ? 4 : 2.2), execute: work)
    }

    func update(_ text: String) {
        guard model.style == .working else { return }
        model.text = L10n.t(text)
    }

    func setProgress(_ fraction: Double) {
        guard model.style == .working else { return }
        model.progress = min(1, max(0, fraction))
    }

    /// The panel is wider than the toast drawn in it, so it takes clicks only while the pointer is on the Cancel button.
    private func watchPointer(_ watch: Bool) {
        pointerTimer?.invalidate()
        pointerTimer = nil
        panel?.ignoresMouseEvents = true
        guard watch else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved(to: NSEvent.mouseLocation) }
        }
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
    }

    /// The Cancel button on the screen, while the toast offers it.
    var cancelButtonRect: NSRect? {
        guard let panel, model.onCancel != nil else { return nil }
        let frame = model.cancelFrame
        return NSRect(x: panel.frame.minX + frame.minX, y: panel.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
    }

    func pointerMoved(to point: NSPoint) {
        guard let button = cancelButtonRect else { return watchPointer(false) }
        panel?.ignoresMouseEvents = !button.insetBy(dx: -3, dy: -3).contains(point)
    }

    private func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = NSSize(width: 440, height: 76)
        panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 8,
                              width: size.width, height: size.height), display: true)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 76),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = FirstClickHostingView(rootView: HUDView(model: model).environment(\.layoutDirection, L10n.direction))
        return panel
    }
}

/// The toast never becomes the active window, so its button has to answer the first click.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct CancelFrameKey: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        HStack(spacing: 9) {
            switch model.style {
            case .working:
                ProgressView().controlSize(.small).tint(Theme.accent)
            case .success:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
            case .failure:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.accent)
            case .cancelled:
                Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.muted)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(model.text)
                        .font(Theme.rounded(12, .medium))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                    if let progress = model.progress, model.style == .working {
                        Text(L10n.t("\(Int(progress * 100))%"))
                            .font(Theme.rounded(11, .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.muted)
                    }
                }
                if let progress = model.progress, model.style == .working {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(Theme.accent)
                        .frame(width: 220)
                        .animation(.easeOut(duration: 0.2), value: progress)
                }
            }
            if model.onCancel != nil, model.style == .working {
                Button(action: model.cancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.black.opacity(0.08)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(L10n.t("Cancel"))
                .accessibilityLabel(L10n.t("Cancel"))
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: CancelFrameKey.self, value: proxy.frame(in: .global))
                })
                .padding(.leading, 3)
            }
        }
        .onPreferenceChange(CancelFrameKey.self) { model.cancelFrame = $0 }
        .font(.system(size: 13, weight: .semibold))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(LightGlass(cornerRadius: 12))
        .environment(\.colorScheme, .light)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
