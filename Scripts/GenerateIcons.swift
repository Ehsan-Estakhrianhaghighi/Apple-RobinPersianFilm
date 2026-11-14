import AppKit
import Foundation

// Generate identical branded assets on every developer Mac and CI runner.
// AppKit is used only at build time; the tvOS/iOS apps do not import it.
func makeIcon(width: Int, height: Int, transparent: Bool = false, markOnly: Bool = false) throws -> Data {
    let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
        let w = rect.width, h = rect.height
        if !transparent {
            NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.20, alpha: 1).setFill()
            NSBezierPath(rect: rect).fill()
            NSColor(calibratedRed: 0.10, green: 0.18, blue: 0.36, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: w * 0.035, dy: h * 0.06),
                         xRadius: min(w,h)*0.13, yRadius: min(w,h)*0.13).fill()
        }
        if !markOnly {
            let centerX = w * 0.50, centerY = h * 0.50
            let radius = min(w, h) * 0.29
            NSColor(calibratedRed: 0.97, green: 0.23, blue: 0.60, alpha: 1).setFill()
            NSBezierPath(ovalIn: CGRect(x: centerX-radius, y: centerY-radius, width: radius*2, height: radius*2)).fill()
            NSColor.white.setFill()
            let triangle = NSBezierPath()
            triangle.move(to: CGPoint(x: centerX-radius*0.28, y: centerY-radius*0.53))
            triangle.line(to: CGPoint(x: centerX-radius*0.28, y: centerY+radius*0.53))
            triangle.line(to: CGPoint(x: centerX+radius*0.60, y: centerY))
            triangle.close()
            triangle.fill()
        }
        return true
    }
    let tiff = image.tiffRepresentation!
    let rep = NSBitmapImageRep(data: tiff)!
    return rep.representation(using: .png, properties: [:])!
}

func save(_ path: String, width: Int, height: Int, transparent: Bool = false, markOnly: Bool = false) throws {
    let dest = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
    try makeIcon(width: width, height: height, transparent: transparent, markOnly: markOnly).write(to: dest)
}

let root = "Assets.xcassets"
let tv = root + "/App Icon & Top Shelf Image.brandassets"
try save(root + "/AppIcon.appiconset/Icon1024.png", width: 1024, height: 1024)
for (folder, width, height) in [("App Icon.imagestack", 400, 240), ("App Icon - App Store.imagestack", 1280, 768)] {
    for layer in ["Back", "Front"] {
        try save(tv + "/\(folder)/\(layer).imagestacklayer/Content.imageset/\(layer).png",
                 width: width, height: height,
                 transparent: layer == "Front", markOnly: layer == "Back")
    }
}
try save(tv + "/Top Shelf Image.imageset/TopShelf.png", width: 1920, height: 720)
print("Generated RobinPersianFilm iOS and tvOS icon artwork.")
