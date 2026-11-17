import SwiftUI

/// TP AI's pointer, drawn over a student's screen in the teacher's live window while TP AI clicks and types.
/// (The student doesn't see it: they get the normal "Your teacher is controlling" banner.)
struct AIPointerOverlay: View {
    let pointer: StudentSession.AIPointer
    let imageSize: CGSize

    static let gradient = LinearGradient(colors: [Color(red: 0.55, green: 0.35, blue: 1.0),
                                                  Color(red: 0.2, green: 0.55, blue: 1.0)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)

    var body: some View {
        GeometryReader { geometry in
            let rect = Self.fit(imageSize, in: geometry.size)
            let spot = CGPoint(x: rect.minX + pointer.x * rect.width, y: rect.minY + pointer.y * rect.height)
            ZStack(alignment: .topLeading) {
                if pointer.clicks > 0 {
                    ClickRipple()
                        .id(pointer.clicks)
                        .position(spot)
                }
                AIPointerArrow(typing: pointer.typing)
                    .offset(x: spot.x, y: spot.y)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .animation(.easeInOut(duration: 0.55), value: pointer.x)
            .animation(.easeInOut(duration: 0.55), value: pointer.y)
        }
    }

    /// Where the student's picture is drawn (it keeps its shape, like the live view).
    static func fit(_ size: CGSize, in bounds: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: bounds) }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let width = size.width * scale, height = size.height * scale
        return CGRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
    }
}

/// The arrow (tip at the exact spot) and its "TP AI" tag.
private struct AIPointerArrow: View {
    let typing: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            ArrowShape()
                .fill(AIPointerOverlay.gradient)
                .overlay(ArrowShape().stroke(Color.white, lineWidth: 2))
                .frame(width: 20, height: 30)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)

            HStack(spacing: 5) {
                Image(systemName: typing == nil ? "sparkles" : "keyboard")
                Text(label).lineLimit(1)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(AIPointerOverlay.gradient))
            .overlay(Capsule().stroke(Color.white.opacity(0.9), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
            .fixedSize()
            .offset(x: 18, y: 26)
        }
    }

    private var label: String {
        guard let typing else { return "TP AI" }
        let shown = typing.replacingOccurrences(of: "\n", with: " ⏎ ")
        return shown.isEmpty ? "TP AI is typing…" : "TP AI is typing: " + String(shown.suffix(40))
    }
}

private struct ArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width / 12, h = rect.height / 19
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: 16 * h))
        path.addLine(to: CGPoint(x: 4 * w, y: 12.5 * h))
        path.addLine(to: CGPoint(x: 7 * w, y: 19 * h))
        path.addLine(to: CGPoint(x: 9.5 * w, y: 18 * h))
        path.addLine(to: CGPoint(x: 6.5 * w, y: 11.5 * h))
        path.addLine(to: CGPoint(x: 12 * w, y: 11.5 * h))
        path.closeSubpath()
        return path
    }
}

/// A ring that grows and fades where TP AI clicks.
private struct ClickRipple: View {
    @State private var grown = false

    var body: some View {
        Circle()
            .stroke(Color(red: 0.45, green: 0.45, blue: 1.0), lineWidth: 4)
            .frame(width: 56, height: 56)
            .scaleEffect(grown ? 1.4 : 0.2)
            .opacity(grown ? 0 : 0.9)
            .onAppear {
                withAnimation(.easeOut(duration: 0.6)) { grown = true }
            }
    }
}
