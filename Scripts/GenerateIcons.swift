import AppKit
import Foundation

// The source is the user's kitten photo. Generate all iOS and tvOS icon
// sizes from that exact image; do not replace it with a generic logo.
guard let photo = NSImage(contentsOfFile: "Scripts/KittenPhoto.jpg") else {
    fatalError("Missing Scripts/KittenPhoto.jpg")
}

func iconPNG(width: Int, height: Int, transparent: Bool = false) throws -> Data {
    let outputSize = NSSize(width: width, height: height)
    let image = NSImage(size: outputSize, flipped: false) { rect in
        guard !transparent else { return true }
        NSGraphicsContext.current?.imageInterpolation = .high
        let sourceSize = photo.size
        let targetRatio = rect.width / rect.height
        let sourceRatio = sourceSize.width / sourceSize.height
        var crop = CGRect(origin: .zero, size: sourceSize)
        if sourceRatio > targetRatio {
            crop.size.width = sourceSize.height * targetRatio
            crop.origin.x = (sourceSize.width - crop.width) / 2
        } else {
            crop.size.height = sourceSize.width / targetRatio
            crop.origin.y = (sourceSize.height - crop.height) / 2
        }
        photo.draw(in: rect, from: crop, operation: .copy, fraction: 1.0)
        return true
    }
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let result = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "RobinIcon", code: 1)
    }
    return result
}

func save(_ destination: String, width: Int, height: Int, transparent: Bool = false) throws {
    let url = URL(fileURLWithPath: destination)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try iconPNG(width: width, height: height, transparent: transparent).write(to: url)
}

let assets = "Assets.xcassets"
let tv = assets + "/App Icon & Top Shelf Image.brandassets"
try save(assets + "/AppIcon.appiconset/Icon1024.png", width: 1024, height: 1024)

for (stack, width, height) in [("App Icon.imagestack", 400, 240),
                                ("App Icon - App Store.imagestack", 1280, 768)] {
    // Back displays the kitten photograph. Front is a transparent layer for
    // tvOS's multilayer icon packaging; the photo remains visually unchanged.
    for layer in ["Back", "Front"] {
        try save(tv + "/\(stack)/\(layer).imagestacklayer/Content.imageset/\(layer).png",
                 width: width, height: height, transparent: layer == "Front")
    }
}
try save(tv + "/Top Shelf Image.imageset/TopShelf.png", width: 1920, height: 720)
print("Generated RobinPersianFilm kitten photo icons for iOS and tvOS.")
