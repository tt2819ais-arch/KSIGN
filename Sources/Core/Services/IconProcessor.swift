import UIKit

enum IconProcessor {

    /// Набор PNG-иконок для инъекции в .app.
    /// Подмена выполняется через CFBundleIcons в Info.plist — это работает и тогда,
    /// когда оригинальные иконки упакованы в Assets.car (иконка из Info.plist имеет приоритет).
    static let iconSet: [(name: String, pixels: Int, ipad: Bool)] = [
        ("AppIcon60x60@2x.png", 120, false),
        ("AppIcon60x60@3x.png", 180, false),
        ("AppIcon76x76@2x~ipad.png", 152, true),
        ("AppIcon83.5x83.5@2x~ipad.png", 167, true)
    ]

    static func renderPNG(from image: UIImage, pixels: Int) -> Data? {
        let size = CGSize(width: pixels, height: pixels)
        let renderer = UIGraphicsImageRenderer(size: size)
        let rendered = renderer.image { ctx in
            let rect = CGRect(origin: .zero, size: size)
            UIColor.white.setFill()
            ctx.fill(rect)
            // aspect-fill
            let scale = max(size.width / image.size.width, size.height / image.size.height)
            let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let origin = CGPoint(x: (size.width - drawSize.width) / 2, y: (size.height - drawSize.height) / 2)
            image.draw(in: CGRect(origin: origin, size: drawSize))
        }
        return rendered.pngData()
    }

    static func prepareSet(from image: UIImage) throws -> [(name: String, data: Data)] {
        var out: [(String, Data)] = []
        for spec in iconSet {
            guard let data = renderPNG(from: image, pixels: spec.pixels), !data.isEmpty else {
                throw AppError.invalidFormat("не удалось подготовить иконку \(spec.name)")
            }
            out.append((spec.name, data))
        }
        return out
    }
}
