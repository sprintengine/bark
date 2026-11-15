// Composes a README showcase image: an app capture with rounded corners and a soft
// drop shadow on a plain neutral backdrop.
//
//   swift docs/images/src/compose.swift <capture.png> <out.png> <light|dark> \
//     [--crop x,y,w,h] [--radius px] [--pad px] [--width px]
//
// <capture.png> comes from the Mac app's screenshot harness (scripts/screenshots.sh): a
// window with transparent rounded corners. --crop cuts a region out of it (in its pixels,
// from the top left) and --radius rounds the cut. --pad sets the backdrop margin (default 7% of
// the longer side); --width scales the result (default 1600).
// render.sh runs every image through this, then pngquant and oxipng.
import AppKit
import CoreGraphics

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("compose: \(message)\n".utf8))
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...i + 1) }
    return args[i + 1]
}
let cropArg = option("--crop")
let radiusArg = option("--radius")
let padArg = option("--pad")
let width = Int(option("--width") ?? "1600") ?? 1600
guard args.count == 3, ["light", "dark"].contains(args[2]) else {
    fail("usage: compose.swift <capture.png> <out.png> <light|dark> [--crop x,y,w,h] [--radius px] [--pad px] [--width px]")
}
let (input, output, dark) = (args[0], args[1], args[2] == "dark")

guard let source = NSImage(contentsOfFile: input)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fail("cannot read \(input)")
}
var image = source
if let cropArg {
    let n = cropArg.split(separator: ",").compactMap { Double($0) }
    let rect = n.count == 4 ? CGRect(x: n[0], y: n[1], width: n[2], height: n[3]) : .null
    // The crop is in the capture's pixels (the harness captures at 2x); it must lie inside it.
    guard !rect.isNull, CGRect(x: 0, y: 0, width: source.width, height: source.height).contains(rect),
          let cut = source.cropping(to: rect) else {
        fail("--crop \(cropArg) is not inside the \(source.width)x\(source.height) capture")
    }
    image = cut
}

// The backdrop: plain and neutral, as the app is. Near-black to graphite in the dark theme,
// white to a soft light grey in the light one.
let colors: [CGColor] = dark
    ? [CGColor(srgbRed: 0x0B / 255, green: 0x0B / 255, blue: 0x0C / 255, alpha: 1),
       CGColor(srgbRed: 0x1F / 255, green: 0x1F / 255, blue: 0x22 / 255, alpha: 1)]
    : [CGColor(srgbRed: 0xE6 / 255, green: 0xE7 / 255, blue: 0xEA / 255, alpha: 1),
       CGColor(srgbRed: 0xF7 / 255, green: 0xF7 / 255, blue: 0xF8 / 255, alpha: 1)]

let w = CGFloat(image.width), h = CGFloat(image.height)
let pad = padArg.flatMap { Double($0) }.map { CGFloat($0) } ?? (max(w, h) * 0.07).rounded()
let canvas = CGSize(width: w + 2 * pad, height: h + 2 * pad)
guard let ctx = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8,
                          bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("no context") }
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: canvas.height), end: CGPoint(x: canvas.width, y: 0), options: [])

let frame = CGRect(x: pad, y: pad, width: w, height: h)
let radius = CGFloat(Double(radiusArg ?? "0") ?? 0)
let shape = CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)

// Shadow: drawn from the image's own alpha (the window's rounded corners), or the crop's shape.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -pad * 0.22), blur: pad * 0.55,
              color: CGColor(gray: 0, alpha: dark ? 0.55 : 0.28))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
if radius > 0 { ctx.addPath(shape); ctx.clip() }
ctx.draw(image, in: frame)
ctx.endTransparencyLayer()
ctx.restoreGState()

guard let composed = ctx.makeImage() else { fail("no image") }
let scale = min(1, CGFloat(width) / canvas.width)
let out = CGSize(width: (canvas.width * scale).rounded(), height: (canvas.height * scale).rounded())
guard let small = CGContext(data: nil, width: Int(out.width), height: Int(out.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("no context") }
small.interpolationQuality = .high
small.draw(composed, in: CGRect(origin: .zero, size: out))
guard let final = small.makeImage(),
      let png = NSBitmapImageRep(cgImage: final).representation(using: .png, properties: [:]) else { fail("no png") }
do { try png.write(to: URL(fileURLWithPath: output)) } catch { fail("cannot write \(output): \(error)") }
