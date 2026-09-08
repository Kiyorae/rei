import SwiftUI

/// Five clicks reveal a short spin without changing the logo's layout or identity.
struct LogoSpinEasterEgg: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var clicks = 0
    @State private var isSpinning = false

    func body(content: Content) -> some View {
        content
            .keyframeAnimator(initialValue: 0.0, trigger: isSpinning) { [reduceMotion] logo, degrees in
                logo.rotationEffect(.degrees(reduceMotion ? 0 : degrees))
            } keyframes: { _ in
                if isSpinning {
                    LinearKeyframe(720, duration: 1.8)
                    SpringKeyframe(1080, duration: 0.7, spring: .bouncy(duration: 0.4, extraBounce: 0.2))
                    MoveKeyframe(1080)
                } else {
                    MoveKeyframe(0)
                }
            }
            .contentShape(.rect)
            .onTapGesture {
                guard !isSpinning, !reduceMotion else { return }
                clicks += 1
                if clicks == 5 {
                    clicks = 0
                    isSpinning = true
                }
            }
            .task(id: isSpinning) {
                guard isSpinning else { return }
                do {
                    try await Task.sleep(for: .milliseconds(2500))
                    isSpinning = false
                } catch is CancellationError {
                    return
                } catch {
                    isSpinning = false
                }
            }
            .onDisappear {
                clicks = 0
                isSpinning = false
            }
    }
}
