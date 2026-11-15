// Turns a flat artwork PNG (squircle on white, no alpha) into a macOS .icns:
// knocks out the white background, trims to the squircle, and re-centres it on
// Apple's 1024px icon grid (824px artwork inside 100px margins).
//
// Usage: swift tools/make-icon.swift <source.png> <output.icns>

import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <source.png> <output.icns>\n".utf8))
    exit(2)
}
let sourceURL = URL(fileURLWithPath: args[1])
let outputURL = URL(fileURLWithPath: args[2])

let canvas = 1024
let artworkSize = 824
let whiteTolerance = 26 // 0-255; how far from pure white counts as background

func loadPixels(_ cg: CGImage) -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
    let ctx = CGContext(data: &pixels, width: cg.width, height: cg.height,
                        bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
    return pixels
}

/// Flood fill from every border pixel across near-white pixels, so white *inside*
/// the artwork (the document, the "Copy" pill) is preserved.
func backgroundMask(_ pixels: [UInt8], width: Int, height: Int) -> [Bool] {
    var mask = [Bool](repeating: false, count: width * height)
    var stack: [Int] = []

    func isBackground(_ index: Int) -> Bool {
        let i = index * 4
        let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
        return 255 - min(r, min(g, b)) <= whiteTolerance
    }

    func seed(_ x: Int, _ y: Int) {
        let index = y * width + x
        if !mask[index], isBackground(index) {
            mask[index] = true
            stack.append(index)
        }
    }

    for x in 0..<width { seed(x, 0); seed(x, height - 1) }
    for y in 0..<height { seed(0, y); seed(width - 1, y) }

    while let index = stack.popLast() {
        let x = index % width, y = index / width
        if x > 0 { seed(x - 1, y) }
        if x < width - 1 { seed(x + 1, y) }
        if y > 0 { seed(x, y - 1) }
        if y < height - 1 { seed(x, y + 1) }
    }
    return mask
}

guard let image = NSImage(contentsOf: sourceURL),
      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
    FileHandle.standardError.write(Data("cannot read \(sourceURL.path)\n".utf8))
    exit(1)
}

let width = cgImage.width, height = cgImage.height
var pixels = loadPixels(cgImage)
let mask = backgroundMask(pixels, width: width, height: height)

// 1px feather on the mask so the knocked-out edge is not jagged.
var alpha = [UInt8](repeating: 255, count: width * height)
for index in 0..<(width * height) {
    alpha[index] = mask[index] ? 0 : 255
}
var feathered = alpha
for y in 0..<height {
    for x in 0..<width {
        var sum = 0, count = 0
        for dy in -1...1 {
            for dx in -1...1 {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                sum += Int(alpha[ny * width + nx])
                count += 1
            }
        }
        feathered[y * width + x] = UInt8(sum / count)
    }
}

var minX = width, maxX = -1, minY = height, maxY = -1
for y in 0..<height {
    for x in 0..<width where feathered[y * width + x] > 8 {
        minX = min(minX, x); maxX = max(maxX, x)
        minY = min(minY, y); maxY = max(maxY, y)
    }
}
guard maxX > minX, maxY > minY else {
    FileHandle.standardError.write(Data("found no artwork after background removal\n".utf8))
    exit(1)
}

for index in 0..<(width * height) {
    pixels[index * 4 + 3] = feathered[index]
}

let trimmed = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    .makeImage()!
    .cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))!

// Re-centre on Apple's grid: 824px artwork with 100px margins.
let square = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8,
                       bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
square.interpolationQuality = .high
let inset = (canvas - artworkSize) / 2
square.draw(trimmed, in: CGRect(x: inset, y: inset, width: artworkSize, height: artworkSize))

let iconsetURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("CopyText-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let variants: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]

for (size, name) in variants {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    context.draw(square.makeImage()!, in: CGRect(x: 0, y: 0, width: size, height: size))
    let png = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
    try png.write(to: iconsetURL.appendingPathComponent(name))
}

// Keep a 1024 master next to the .icns for future use.
let master = NSBitmapImageRep(cgImage: square.makeImage()!)
    .representation(using: .png, properties: [:])!
try master.write(to: outputURL.deletingLastPathComponent().appendingPathComponent("AppIcon-1024.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconsetURL)

guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
print("wrote \(outputURL.path) (artwork \(maxX - minX + 1)x\(maxY - minY + 1) from \(width)x\(height) source)")
