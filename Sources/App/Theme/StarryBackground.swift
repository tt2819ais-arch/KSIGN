import SwiftUI

/// Оптимизированный по батарее звёздный фон:
/// ~120 звёзд, Canvas + TimelineView с кадровой частотой 20 fps,
/// медленный дрейф с параллаксом и мягкое мерцание.
/// При включённом Reduce Motion анимация полностью останавливается.
struct StarryBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Star {
        var x: Double, y: Double
        var depth: Double      // 0.2...1
        var radius: Double
        var phase: Double
    }

    private let stars: [Star] = (0..<120).map { _ in
        Star(x: .random(in: 0...1), y: .random(in: 0...1),
             depth: .random(in: 0.2...1),
             radius: .random(in: 0.6...1.9),
             phase: .random(in: 0...(2 * .pi)))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: reduceMotion)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                for s in stars {
                    let drift = reduceMotion ? 0 : (t * 0.004 * s.depth)
                    let x = (s.x + drift).truncatingRemainder(dividingBy: 1) * size.width
                    let y = s.y * size.height
                    let twinkle = reduceMotion ? 1.0
                        : 0.75 + 0.25 * sin(t * 1.4 + s.phase)
                    let alpha = (0.25 + 0.6 * s.depth) * twinkle
                    let rect = CGRect(x: x, y: y, width: s.radius * 2, height: s.radius * 2)
                    context.fill(Path(ellipseIn: rect),
                                 with: .color(Color.white.opacity(alpha)))
                }
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
