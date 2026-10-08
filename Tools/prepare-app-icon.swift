import AppKit
import ImageIO

// Remove the connected outer white matte and its antialias fringe.
// The approved artwork inside the rounded tile stays unchanged.
guard CommandLine.arguments.count == 3 else {
    fputs("Usage: swift Tools/prepare-app-icon.swift input.png output.png\n", stderr)
    exit(1)
}
let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      image.width == 1024, image.height == 1024 else {
    fputs("Expected a 1024 × 1024 PNG\n", stderr)
    exit(1)
}
let w = image.width, h = image.height, count = w*h
let format = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
var pixels = [UInt8](repeating: 0, count: count*4)
pixels.withUnsafeMutableBytes { bytes in
    let context = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: format)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
}
func isMatte(_ i: Int) -> Bool {
    let channels = [Int(pixels[i*4]), Int(pixels[i*4+1]), Int(pixels[i*4+2])]
    return channels.min()! >= 180 && channels.max()! - channels.min()! <= 64
}
var outer = [Bool](repeating: false, count: count)
var queue: [Int] = []
func visit(_ i: Int) {
    if !outer[i] && isMatte(i) { outer[i] = true; queue.append(i) }
}
for x in 0..<w { visit(x); visit((h-1)*w+x) }
for y in 0..<h { visit(y*w); visit(y*w+w-1) }
var cursor = 0
while cursor < queue.count {
    let i = queue[cursor], x = i%w, y = i/w
    cursor += 1
    if x > 0 { visit(i-1) }
    if x < w-1 { visit(i+1) }
    if y > 0 { visit(i-w) }
    if y < h-1 { visit(i+w) }
}
var result = pixels, transparent = 0, fringe = 0
for y in 0..<h { for x in 0..<w {
    let i = y*w+x
    var boundary = false
    for dy in -2...2 { for dx in -2...2 {
        let xx = x+dx, yy = y+dy
        if xx >= 0 && xx < w && yy >= 0 && yy < h && outer[yy*w+xx] != outer[i] {
            boundary = true
        }
    }}
    if boundary {
        // Undo white matting in premultiplied RGB. Compositing onto white
        // reproduces the source edge, without a white halo on dark desktops.
        let white = min(pixels[i*4], pixels[i*4+1], pixels[i*4+2])
        for c in 0..<3 { result[i*4+c] = pixels[i*4+c]-white }
        result[i*4+3] = 255-white
        fringe += 1
    } else if outer[i] {
        for c in 0..<4 { result[i*4+c] = 0 }
        transparent += 1
    }
}}
guard transparent > 100_000 && result[(512*w+512)*4+3] == 255 else {
    fputs("Refusing to export: unexpected exterior mask\n", stderr)
    exit(1)
}
let provider = CGDataProvider(data: Data(result) as CFData)!
let prepared = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: w*4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: format), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, prepared, nil)
guard CGImageDestinationFinalize(destination) else {
    fputs("PNG export failed\n", stderr)
    exit(1)
}
print("Prepared icon: \(transparent) transparent exterior pixels; \(fringe) edge pixels; interior unchanged")
