#!/usr/bin/env swift
// AITL Bridge icon: Caeruli Obscuri squircle (void -> midnight) with a caerulei signal ring and a bright core dot.
import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else { FileHandle.standardError.write("usage: make-icon.swift <output.iconset>\n".data(using: .utf8)!); exit(1) }
let outDir = URL(fileURLWithPath: args[1])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func draw(size s: CGFloat, ctx: CGContext) {
    ctx.setAllowsAntialiasing(true); ctx.interpolationQuality = .high
    let inset = s * 0.055
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = CGPath(roundedRect: rect, cornerWidth: s * 0.225, cornerHeight: s * 0.225, transform: nil)
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    let bg = [CGColor(red: 0.055, green: 0.114, blue: 0.239, alpha: 1), CGColor(red: 0.008, green: 0.020, blue: 0.051, alpha: 1)] as CFArray
    if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: bg, locations: [0, 1]) {
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
    }
    // glow
    let glow = [CGColor(red: 0.29, green: 0.78, blue: 1.0, alpha: 0.45), CGColor(red: 0.29, green: 0.78, blue: 1.0, alpha: 0.0)] as CFArray
    if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: glow, locations: [0, 1]) {
        ctx.drawRadialGradient(g, startCenter: CGPoint(x: s / 2, y: s / 2), startRadius: 0, endCenter: CGPoint(x: s / 2, y: s / 2), endRadius: s * 0.4, options: [])
    }
    ctx.restoreGState()
    let c = CGPoint(x: s / 2, y: s / 2)
    let caerulei = CGColor(red: 0.29, green: 0.78, blue: 1.0, alpha: 1)
    // signal rings
    for (i, r) in [0.34, 0.24].enumerated() {
        ctx.setStrokeColor(CGColor(red: 0.29, green: 0.78, blue: 1.0, alpha: i == 0 ? 0.55 : 0.85))
        ctx.setLineWidth(s * 0.045)
        ctx.addArc(center: c, radius: s * r, startAngle: .pi * 0.15, endAngle: .pi * 0.85, clockwise: false); ctx.strokePath()
        ctx.addArc(center: c, radius: s * r, startAngle: .pi * 1.15, endAngle: .pi * 1.85, clockwise: false); ctx.strokePath()
    }
    // core
    ctx.setFillColor(CGColor(red: 0.91, green: 0.93, blue: 0.96, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: c.x - s * 0.085, y: c.y - s * 0.085, width: s * 0.17, height: s * 0.17))
    ctx.setFillColor(caerulei)
    ctx.fillEllipse(in: CGRect(x: c.x - s * 0.05, y: c.y - s * 0.05, width: s * 0.1, height: s * 0.1))
}

for (px, name) in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"), (128, "128x128"), (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")] {
    let size = CGFloat(px)
    guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
    draw(size: size, ctx: ctx)
    guard let img = ctx.makeImage() else { continue }
    let rep = NSBitmapImageRep(cgImage: img)
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: outDir.appendingPathComponent("icon_\(name).png"))
    }
}
