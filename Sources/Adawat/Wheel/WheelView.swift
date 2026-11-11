import SwiftUI

struct WheelView: View {
    @ObservedObject var model: WheelModel

    private let size = WheelGeometry.size

    var body: some View {
        ZStack {
            disc
            ZStack {
                ForEach(Array(model.operations.enumerated()), id: \.element.id) { index, operation in
                    Petal(operation: operation, index: index, count: model.operations.count,
                          isHovered: model.hoveredIndex == index)
                }
            }
            .shadow(color: Theme.shadow, radius: 8, y: 5)
            centerLabel
        }
        .frame(width: size, height: size)
        .environment(\.colorScheme, .light)
        // Petals are placed by angle; mirroring would swap them with their drop zones.
        .environment(\.layoutDirection, .leftToRight)
        .scaleEffect(model.isVisible ? 1 : 0.9)
        .opacity(model.isVisible ? 1 : 0)
        .animation(.spring(response: 0.26, dampingFraction: 0.8), value: model.isVisible)
        .animation(.easeOut(duration: 0.12), value: model.hoveredIndex)
    }

    /// Frosted ring behind the petals, open in the middle.
    private var disc: some View {
        let diameter = (WheelGeometry.outerRadius + 6.5) * 2
        return Circle()
            .fill(.ultraThinMaterial)
            .overlay(Circle().fill(Theme.discTint))
            .overlay(Circle().strokeBorder(.white.opacity(0.33), lineWidth: 1))
            .mask(
                Circle()
                    .strokeBorder(lineWidth: diameter / 2 - (WheelGeometry.innerRadius - 6))
            )
            .frame(width: diameter, height: diameter)
    }

    private var centerLabel: some View {
        let operation = model.hoveredOperation
        let isTool = operation.map { $0.badge == nil } ?? false
        let text = operation?.wheelLabel ?? (model.operations.isEmpty ? "NO OPTIONS" : (L10n.isArabic ? L10n.t(model.mode.title) : model.mode.title.uppercased()))
        return Text(text)
            .font(Theme.rounded(isTool || operation == nil ? 8.5 : 12, isTool || operation == nil ? .semibold : .medium))
            .tracking(isTool ? 0.2 : 0.35)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.7)
            .foregroundStyle(.black)
            .frame(width: 58)
            .padding(.horizontal, 6)
            .frame(minHeight: isTool ? 36 : 32)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.white.opacity(0.72))
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            )
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.7)))
            .shadow(color: .black.opacity(0.063), radius: 3, y: 2)
    }
}

private struct Petal: View {
    let operation: AdawatOperation
    let index: Int
    let count: Int
    let isHovered: Bool

    var body: some View {
        let shape = PetalShape(index: index, count: count)
        ZStack {
            shape.fill(isHovered ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.petalFill))
            shape.stroke(isHovered ? Theme.accentStroke : Theme.petalStroke, lineWidth: 0.75)
            label.position(WheelGeometry.position(index: index, count: count))
        }
        .frame(width: WheelGeometry.size, height: WheelGeometry.size)
        .offset(isHovered ? lift : .zero)
        .shadow(color: isHovered ? Theme.accent.opacity(0.35) : .clear, radius: 6, y: 3)
    }

    /// Moves the hovered petal a few points outward along its center line.
    private var lift: CGSize {
        guard count > 1 else { return .zero }
        let angle = -Double.pi / 2 + Double(index) / Double(count) * 2 * Double.pi
        return CGSize(width: cos(angle) * 5, height: sin(angle) * 5)
    }

    @ViewBuilder
    private var label: some View {
        let color: Color = isHovered ? .white : .black
        if let badge = operation.badge {
            Text(badge.uppercased())
                .font(Theme.rounded(count > 8 ? 12 : 14, .semibold))
                .tracking(0.35)
                .foregroundStyle(color)
        } else {
            VStack(spacing: 4) {
                Image(systemName: operation.systemImage)
                    .font(.system(size: 13, weight: .medium))
                Text(operation.wheelLabel)
                    .font(Theme.rounded(8.5, .semibold))
                    .tracking(0.2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: 62)
            }
            .foregroundStyle(color)
        }
    }
}

/// One rounded annular sector of the wheel, separated from its neighbours by a small gap.
struct PetalShape: Shape {
    let index: Int
    let count: Int

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let ri = WheelGeometry.innerRadius
        let ro = WheelGeometry.outerRadius
        let gap: CGFloat = 2
        let innerCorner: CGFloat = 7
        let outerCorner: CGFloat = 20

        let step = 2 * Double.pi / Double(max(count, 1))
        let mid = -Double.pi / 2 + Double(index) * step
        // A single option is a full ring; draw it as two concentric circles.
        if count == 1 {
            var path = Path()
            path.addEllipse(in: CGRect(x: center.x - ro, y: center.y - ro, width: ro * 2, height: ro * 2))
            path.addEllipse(in: CGRect(x: center.x - ri, y: center.y - ri, width: ri * 2, height: ri * 2))
            return path.normalized(eoFill: true)
        }
        let start = mid - step / 2
        let end = mid + step / 2

        func point(_ radius: CGFloat, _ angle: Double) -> CGPoint {
            CGPoint(x: center.x + radius * CGFloat(cos(angle)), y: center.y + radius * CGFloat(sin(angle)))
        }
        func toward(_ from: CGPoint, _ to: CGPoint, _ distance: CGFloat) -> CGPoint {
            let length = hypot(to.x - from.x, to.y - from.y)
            guard length > 0 else { return from }
            let t = min(distance / length, 0.5)
            return CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
        }
        func arc(_ path: inout Path, radius: CGFloat, from a0: Double, to a1: Double) {
            let segments = 28
            for i in 1...segments {
                path.addLine(to: point(radius, a0 + (a1 - a0) * Double(i) / Double(segments)))
            }
        }

        // Each side edge is the boundary radius offset by `gap`, which is asin(gap / r) in angle.
        let i0 = start + asin(gap / ri), o0 = start + asin(gap / ro)
        let o1 = end - asin(gap / ro), i1 = end - asin(gap / ri)
        let I0 = point(ri, i0), O0 = point(ro, o0), O1 = point(ro, o1), I1 = point(ri, i1)

        var path = Path()
        path.move(to: toward(I0, O0, innerCorner))
        path.addLine(to: toward(O0, I0, outerCorner))
        path.addQuadCurve(to: point(ro, o0 + outerCorner / ro), control: O0)
        arc(&path, radius: ro, from: o0 + outerCorner / ro, to: o1 - outerCorner / ro)
        path.addQuadCurve(to: toward(O1, I1, outerCorner), control: O1)
        path.addLine(to: toward(I1, O1, innerCorner))
        path.addQuadCurve(to: point(ri, i1 - innerCorner / ri), control: I1)
        arc(&path, radius: ri, from: i1 - innerCorner / ri, to: i0 + innerCorner / ri)
        path.addQuadCurve(to: toward(I0, O0, innerCorner), control: I0)
        path.closeSubpath()
        return path
    }
}
