import AppKit
import ImageIO

// Exact, repeatable block sampling for the user's block-size/filter study.
// The saved master stays untouched. Only the protected emblem interior is blended.
struct RGB {
    var r: Float = 0, g: Float = 0, b: Float = 0
    static func +(a: RGB, b: RGB) -> RGB { RGB(r: a.r+b.r, g: a.g+b.g, b: a.b+b.b) }
    static func *(a: RGB, b: Float) -> RGB { RGB(r: a.r*b, g: a.g*b, b: a.b*b) }
}
func clamp(_ x: Float) -> Float { min(1, max(0, x)) }
func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = clamp((x-a)/(b-a)); return t*t*(3-2*t)
}
struct Profile {
    let key: String, title: String
    let small: Int, large: Int
    let sigma: Float, blend: Float, levels: Float
}
let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
let cg = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(sourceURL as CFURL, nil)!, 0, nil)!
let w = cg.width, h = cg.height, n = w*h
guard w == 1024 && h == 1024 else { fatalError("The study uses 1024px source coordinates") }
var sourceBytes = [UInt8](repeating: 0, count: n*4)
let format = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
sourceBytes.withUnsafeMutableBytes { bytes in
    let ctx = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8,
                        bytesPerRow: w*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: format)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
}
let source = (0..<n).map { i in RGB(r: Float(sourceBytes[i*4])/255,
                                  g: Float(sourceBytes[i*4+1])/255, b: Float(sourceBytes[i*4+2])/255) }
var inside = [Bool](repeating: false, count: n)
for y in 210..<785 {
    for x in 105..<925 {
        let i = y*w+x, c = source[i]
        inside[i] = c.g > 0.27 && c.g > c.r*1.12 && c.g > c.b*1.12
    }
}
var distance = inside.map { $0 ? Float(4096) : Float(0) }
for y in 1..<h {
    for x in 1..<w {
        let i = y*w+x
        distance[i] = min(distance[i], distance[i-1]+1, distance[i-w]+1, distance[i-w-1]+1.4142)
    }
}
for y in stride(from: h-2, through: 0, by: -1) {
    for x in stride(from: w-2, through: 0, by: -1) {
        let i = y*w+x
        distance[i] = min(distance[i], distance[i+1]+1, distance[i+w]+1, distance[i+w+1]+1.4142)
    }
}
var protection = [Float](repeating: 0, count: n)
for y in 3..<(h-3) {
    for x in 3..<(w-3) {
        let i = y*w+x
        guard inside[i] else { continue }
        let gx = abs(source[i+2].g-source[i-2].g)
        let gy = abs(source[i+w*2].g-source[i-w*2].g)
        let edge = max(gx, gy)
        protection[i] = smooth(2, 12, distance[i]) * (1-0.95*smooth(0.08, 0.24, edge))
    }
}

func blur(_ source: [RGB], sigma: Float) -> [RGB] {
    let radius = max(1, Int(ceil(sigma*3)))
    var kernel = (-radius...radius).map { exp(-Float($0*$0)/(2*sigma*sigma)) }
    let sum = kernel.reduce(0,+); kernel = kernel.map { $0/sum }
    var horizontal = [RGB](repeating: RGB(), count: n), result = horizontal
    for y in 0..<h { for x in 0..<w {
        var c = RGB()
        for k in -radius...radius { c = c + source[y*w+min(w-1,max(0,x+k))]*kernel[k+radius] }
        horizontal[y*w+x] = c
    }}
    for y in 0..<h { for x in 0..<w {
        var c = RGB()
        for k in -radius...radius { c = c + horizontal[min(h-1,max(0,y+k))*w+x]*kernel[k+radius] }
        result[y*w+x] = c
    }}
    return result
}
func blocks(_ source: [RGB], size: Int, levels: Float) -> [RGB] {
    var result = source
    for top in stride(from: 0, to: h, by: size) {
        for left in stride(from: 0, to: w, by: size) {
            var average = RGB(), count: Float = 0
            for y in top..<min(h,top+size) { for x in left..<min(w,left+size) {
                let i = y*w+x
                guard inside[i] else { continue }
                average = average + source[i]; count += 1
            }}
            guard count > 0 else { continue }
            average = average*(1/count)
            // Limited green tones give blocks a gentle, coherent pixel-art shading.
            average = RGB(r: round(average.r*levels)/levels, g: round(average.g*levels)/levels,
                          b: round(average.b*levels)/levels)
            for y in top..<min(h,top+size) { for x in left..<min(w,left+size) {
                result[y*w+x] = average
            }}
        }
    }
    return result
}
func save(_ bytes: [UInt8], to url: URL) throws {
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                        bytesPerRow: w*4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo(rawValue: format), provider: provider,
                        decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("PNG export failed") }
}
let profiles = [
    Profile(key: "A", title: "细颗粒", small: 4, large: 10, sigma: 0.55, blend: 0.28, levels: 32),
    Profile(key: "B", title: "均衡", small: 6, large: 16, sigma: 0.85, blend: 0.42, levels: 24),
    Profile(key: "C", title: "明显", small: 8, large: 24, sigma: 1.20, blend: 0.58, levels: 20)
]
var manifest: [[String: Any]] = []
for p in profiles {
    let filtered = blur(source, sigma: p.sigma)
    let small = blocks(filtered, size: p.small, levels: p.levels)
    let large = blocks(filtered, size: p.large, levels: p.levels)
    var output = sourceBytes, changed = 0, protectedChanges = 0, totalDelta: Float = 0
    for i in 0..<n {
        let amount = protection[i]*p.blend
        guard amount > 0 else { continue }
        let detail = clamp(smooth(0.68,0.94,source[i].g)*0.75 + (1-smooth(5,24,distance[i]))*0.65)
        let pix = small[i]*detail + large[i]*(1-detail)
        let color = source[i]*(1-amount) + pix*amount
        let channels = [color.r, color.g, color.b]
        for k in 0..<3 { output[i*4+k] = UInt8(round(clamp(channels[k])*255)) }
        if output[i*4] != sourceBytes[i*4] || output[i*4+1] != sourceBytes[i*4+1] || output[i*4+2] != sourceBytes[i*4+2] {
            changed += 1
            if !inside[i] || distance[i] <= 2 { protectedChanges += 1 }
            totalDelta += abs(color.r-source[i].r) + abs(color.g-source[i].g) + abs(color.b-source[i].b)
        }
    }
    guard protectedChanges == 0 && changed > 1000 else { fatalError("Protected-edge validation failed") }
    let url = outputURL.appendingPathComponent("MobiusGreen-filter-\(p.key).png")
    try save(output, to: url)
    let record: [String: Any] = ["id": p.key, "title": p.title, "blockSizes": [p.small,p.large],
        "gaussianSigma": p.sigma, "blend": p.blend, "greenLevels": p.levels, "path": url.path,
        "changedPixels": changed, "changesOutsideInterior": protectedChanges,
        "averageChannelDelta": totalDelta/Float(changed*3)]
    manifest.append(record)
    print("\(p.key): blocks \(p.small)/\(p.large) px, blur \(p.sigma), blend \(p.blend), modified \(changed), protected changes \(protectedChanges)")
}
try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted,.sortedKeys])
    .write(to: outputURL.appendingPathComponent("filter-settings.json"))
