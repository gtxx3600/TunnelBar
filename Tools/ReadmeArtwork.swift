import AppKit

/// README 封面：只为真实界面截图添加展示背景，不改变界面内容。
/// 在项目根目录通过 Tools/update-readme-images.sh 运行。
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let canvas = NSSize(width: 1600, height: 900)
guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width),
                                   pixelsHigh: Int(canvas.height), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("无法创建 README 封面画布")
}
bitmap.size = canvas
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

// 展示布局使用左上角坐标；AppKit 的绘制坐标从左下角开始。
func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
    NSRect(x: x, y: canvas.height - y - height, width: width, height: height)
}

func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat,
          weight: NSFont.Weight = .regular, foreground: NSColor) {
    let string = NSAttributedString(string: value, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: foreground
    ])
    let bounds = string.size()
    string.draw(in: rect(x, y, ceil(bounds.width) + 2, ceil(bounds.height) + 2))
}

func image(_ path: String, in frame: NSRect) throws {
    guard let source = NSImage(contentsOfFile: path) else {
        throw NSError(domain: "ReadmeArtwork", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "无法读取图片：\(path)"])
    }
    source.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
}

let foreground = color(238, 247, 243)
let muted = color(153, 178, 169)
let green = color(106, 236, 167)
let background = NSBezierPath(rect: NSRect(origin: .zero, size: canvas))
NSGradient(starting: color(11, 25, 21), ending: color(19, 40, 32))!.draw(in: background, angle: 18)

// 稀疏的连接轨迹为界面留出空间，并呼应应用图标的环形轮廓。
for diameter in [CGFloat(730), 1010, 1320] {
    let circle = NSBezierPath(ovalIn: rect(1240 - diameter / 2, 460 - diameter / 2, diameter, diameter))
    color(115, 212, 163, alpha: 0.065).setStroke()
    circle.lineWidth = 1.5
    circle.stroke()
}
let divider = NSBezierPath()
divider.move(to: NSPoint(x: 88, y: canvas.height - 740))
divider.line(to: NSPoint(x: 850, y: canvas.height - 740))
color(111, 168, 139, alpha: 0.20).setStroke()
divider.lineWidth = 1
divider.stroke()

try image("Resources/AppIcon.png", in: rect(78, 65, 90, 90))
text("TunnelBar", x: 182, y: 85, size: 39, weight: .semibold, foreground: foreground)
text("SSH 隧道，", x: 88, y: 240, size: 70, weight: .semibold, foreground: foreground)
text("随手可控。", x: 88, y: 331, size: 70, weight: .semibold, foreground: green)
text("数据库、内网网页、SOCKS 代理", x: 91, y: 450, size: 27, foreground: muted)
text("在 macOS 菜单栏里统一管理。", x: 91, y: 495, size: 27, foreground: muted)

for (label, x) in [("菜单栏启停", CGFloat(90)), ("断线重连", CGFloat(286)), ("项目分组", CGFloat(462))] {
    let width: CGFloat = label.count == 5 ? 172 : 152
    let pill = NSBezierPath(roundedRect: rect(x, 596, width, 52), xRadius: 26, yRadius: 26)
    color(41, 81, 62, alpha: 0.45).setFill()
    pill.fill()
    color(96, 166, 127, alpha: 0.30).setStroke()
    pill.lineWidth = 1
    pill.stroke()
    text(label, x: x + 24, y: 607, size: 23, weight: .medium, foreground: green)
}
text("macOS 13+   /   原生 SwiftUI   /   OpenSSH", x: 91, y: 785, size: 22, foreground: muted)

let panelPath = "build/panel-preview/dark-readme.png"
guard let panel = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: panelPath))) else {
    fatalError("无法读取菜单栏预览")
}
let panelWidth: CGFloat = 500
let panelHeight = panelWidth * CGFloat(panel.pixelsHigh) / CGFloat(panel.pixelsWide)
let panelFrame = rect(998, 220, panelWidth, panelHeight)
text("菜单栏面板 · 深色外观", x: 1004, y: 174, size: 20, foreground: muted)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.40)
shadow.shadowBlurRadius = 40
shadow.shadowOffset = NSSize(width: 0, height: -16)
shadow.set()
color(31, 31, 31).setFill()
NSBezierPath(roundedRect: panelFrame, xRadius: 21, yRadius: 21).fill()
NSGraphicsContext.restoreGraphicsState()
try image(panelPath, in: panelFrame)

NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("无法导出 README 封面")
}
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
try png.write(to: output.appendingPathComponent("hero.png"))
print("hero.png: \(Int(canvas.width)) × \(Int(canvas.height)) px")
