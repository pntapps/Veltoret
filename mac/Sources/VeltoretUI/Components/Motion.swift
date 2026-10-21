import SwiftUI

/// Motion (Android `ui/components/Motion.kt`, Windows `Motion.cs`).
///
/// - Press scale: cards 0.96, buttons 0.97, icon buttons 0.94, springy. Built into the button styles; for custom
///   clickables use `Button { } label: { }.buttonStyle(VPlainButtonStyle(pressScale: 0.96))`.
/// - Entrance: `.vEntrance(index)` fades in and rises 18 pt after `index × 70 ms`; plays once per `key` (or once per
///   view identity when no key), never again when scrolled back into view.
public enum Motion {
    /// Android spring (damping 0.6, stiffness ≈ 400).
    public static let pressSpring = Animation.spring(response: 0.28, dampingFraction: 0.6)
    /// FastOutSlowIn (cubic-bezier 0.4, 0, 0.2, 1).
    public static func fastOutSlowIn(_ seconds: Double) -> Animation { .timingCurve(0.4, 0, 0.2, 1, duration: seconds) }

    @MainActor static var playedEntrances = Set<String>()
}

private struct EntranceModifier: ViewModifier {
    let index: Int
    let baseDelayMs: Int
    let key: String?
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 18)
            .onAppear {
                if shown { return }
                if let key, Motion.playedEntrances.contains(key) { shown = true; return }
                if let key { Motion.playedEntrances.insert(key) }
                let delay = Double(baseDelayMs + index * 70) / 1000
                withAnimation(Motion.fastOutSlowIn(0.42).delay(delay)) { shown = true }
            }
    }
}

public extension View {
    /// One-time entrance: fade in + rise 18 pt after `baseDelayMs + index × 70` ms. Pass a stable `key`
    /// (e.g. "home.hero") so it never replays for the same element, even after the view is rebuilt.
    func vEntrance(_ index: Int, baseDelayMs: Int = 0, key: String? = nil) -> some View {
        modifier(EntranceModifier(index: index, baseDelayMs: baseDelayMs, key: key))
    }

    /// Scales to `scale` while `pressed` (springy). Button styles use this already.
    func vPressScale(_ pressed: Bool, _ scale: CGFloat = 0.97) -> some View {
        scaleEffect(pressed ? scale : 1).animation(Motion.pressSpring, value: pressed)
    }
}
