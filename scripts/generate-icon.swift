#!/usr/bin/env swift

import AppKit
import Darwin
import Foundation

struct IconSpec {
    let pointSize: Int
    let scale: Int

    var pixelSize: Int { pointSize * scale }
    var filename: String {
        let scaleSuffix = scale == 1 ? "" : "@\(scale)x"
        return "icon_\(pointSize)x\(pointSize)\(scaleSuffix).png"
    }
}

struct AssetContents: Encodable {
    struct Image: Encodable {
        let filename: String
        let idiom: String
        let scale: String
        let size: String
    }

    struct Info: Encodable {
        let author: String
        let version: Int
    }

    let images: [Image]
    let info: Info
}

enum IconGenerationError: LocalizedError {
    case bitmapCreationFailed(Int)
    case graphicsContextUnavailable
    case gradientCreationFailed(String)
    case pngEncodingFailed(String)
    case invalidGeneratedDimensions(path: String, expected: Int, actualWidth: Int, actualHeight: Int)

    var errorDescription: String? {
        switch self {
        case .bitmapCreationFailed(let size):
            return "Could not create a \(size)x\(size) bitmap."
        case .graphicsContextUnavailable:
            return "Could not create an AppKit graphics context."
        case .gradientCreationFailed(let name):
            return "Could not create the \(name) gradient."
        case .pngEncodingFailed(let path):
            return "Could not encode PNG data for \(path)."
        case let .invalidGeneratedDimensions(path, expected, actualWidth, actualHeight):
            return "Generated \(path) at \(actualWidth)x\(actualHeight); expected \(expected)x\(expected)."
        }
    }
}

let iconSpecs = [16, 32, 128, 256, 512].flatMap { pointSize in
    [1, 2].map { scale in IconSpec(pointSize: pointSize, scale: scale) }
}

func makeGradient(colors: [NSColor], name: String) throws -> NSGradient {
    guard let gradient = NSGradient(colors: colors) else {
        throw IconGenerationError.gradientCreationFailed(name)
    }
    return gradient
}

func createShieldIcon(size: CGFloat) throws -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    guard let context = NSGraphicsContext.current?.cgContext else {
        throw IconGenerationError.graphicsContextUnavailable
    }

    let padding = size * 0.08
    let drawSize = size - (padding * 2)
    let centerX = size / 2
    let centerY = size / 2

    let shieldPath = NSBezierPath()
    let shieldWidth = drawSize * 0.8
    let shieldHeight = drawSize * 0.9
    let topY = centerY + shieldHeight * 0.45
    let bottomY = centerY - shieldHeight * 0.55
    let midY = centerY - shieldHeight * 0.05

    let topLeft = CGPoint(x: centerX - shieldWidth / 2, y: topY - shieldHeight * 0.1)
    let topRight = CGPoint(x: centerX + shieldWidth / 2, y: topY - shieldHeight * 0.1)
    let topCenter = CGPoint(x: centerX, y: topY)
    let bottomPoint = CGPoint(x: centerX, y: bottomY)
    let leftMid = CGPoint(x: centerX - shieldWidth / 2, y: midY)
    let rightMid = CGPoint(x: centerX + shieldWidth / 2, y: midY)

    shieldPath.move(to: topCenter)
    shieldPath.curve(
        to: topRight,
        controlPoint1: CGPoint(x: centerX + shieldWidth * 0.25, y: topY),
        controlPoint2: CGPoint(x: centerX + shieldWidth * 0.4, y: topY - shieldHeight * 0.05)
    )
    shieldPath.line(to: rightMid)
    shieldPath.curve(
        to: bottomPoint,
        controlPoint1: CGPoint(x: centerX + shieldWidth / 2, y: midY - shieldHeight * 0.2),
        controlPoint2: CGPoint(x: centerX + shieldWidth * 0.2, y: bottomY + shieldHeight * 0.1)
    )
    shieldPath.curve(
        to: leftMid,
        controlPoint1: CGPoint(x: centerX - shieldWidth * 0.2, y: bottomY + shieldHeight * 0.1),
        controlPoint2: CGPoint(x: centerX - shieldWidth / 2, y: midY - shieldHeight * 0.2)
    )
    shieldPath.line(to: topLeft)
    shieldPath.curve(
        to: topCenter,
        controlPoint1: CGPoint(x: centerX - shieldWidth * 0.4, y: topY - shieldHeight * 0.05),
        controlPoint2: CGPoint(x: centerX - shieldWidth * 0.25, y: topY)
    )
    shieldPath.close()

    let shieldGradient = try makeGradient(
        colors: [
            NSColor(red: 0.204, green: 0.780, blue: 0.349, alpha: 1.0),
            NSColor(red: 0.0, green: 0.780, blue: 0.745, alpha: 1.0)
        ],
        name: "shield"
    )
    let highlightGradient = try makeGradient(
        colors: [NSColor.white.withAlphaComponent(0.3), NSColor.white.withAlphaComponent(0.0)],
        name: "highlight"
    )

    context.saveGState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.02)
    shadow.shadowBlurRadius = size * 0.05
    shadow.set()
    shieldGradient.draw(in: shieldPath, angle: -90)
    context.restoreGState()

    context.saveGState()
    shieldPath.addClip()
    let highlightRect = NSRect(
        x: centerX - shieldWidth / 2,
        y: centerY,
        width: shieldWidth,
        height: shieldHeight / 2
    )
    highlightGradient.draw(in: highlightRect, angle: -90)
    context.restoreGState()

    let checkPath = NSBezierPath()
    let checkSize = drawSize * 0.35
    let checkCenterY = centerY - shieldHeight * 0.05
    checkPath.move(to: CGPoint(x: centerX - checkSize * 0.4, y: checkCenterY))
    checkPath.line(to: CGPoint(x: centerX - checkSize * 0.1, y: checkCenterY - checkSize * 0.3))
    checkPath.line(to: CGPoint(x: centerX + checkSize * 0.45, y: checkCenterY + checkSize * 0.4))
    checkPath.lineWidth = size * 0.06
    checkPath.lineCapStyle = .round
    checkPath.lineJoinStyle = .round

    context.saveGState()
    let checkShadow = NSShadow()
    checkShadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
    checkShadow.shadowOffset = NSSize(width: 0, height: -size * 0.01)
    checkShadow.shadowBlurRadius = size * 0.02
    checkShadow.set()
    NSColor.white.setStroke()
    checkPath.stroke()
    context.restoreGState()

    return image
}

func savePNG(_ image: NSImage, to url: URL, pixelSize: Int) throws {
    guard let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw IconGenerationError.bitmapCreationFailed(pixelSize)
    }

    representation.size = NSSize(width: pixelSize, height: pixelSize)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }

    guard let graphicsContext = NSGraphicsContext(bitmapImageRep: representation) else {
        throw IconGenerationError.graphicsContextUnavailable
    }
    NSGraphicsContext.current = graphicsContext
    image.draw(
        in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
        from: NSRect(origin: .zero, size: image.size),
        operation: .copy,
        fraction: 1.0
    )

    guard let data = representation.representation(using: .png, properties: [:]) else {
        throw IconGenerationError.pngEncodingFailed(url.path)
    }
    try data.write(to: url, options: .atomic)

    guard
        let generated = NSBitmapImageRep(data: data),
        generated.pixelsWide == pixelSize,
        generated.pixelsHigh == pixelSize
    else {
        let generated = NSBitmapImageRep(data: data)
        throw IconGenerationError.invalidGeneratedDimensions(
            path: url.path,
            expected: pixelSize,
            actualWidth: generated?.pixelsWide ?? 0,
            actualHeight: generated?.pixelsHigh ?? 0
        )
    }
}

func writeContents(to directory: URL) throws {
    let contents = AssetContents(
        images: iconSpecs.map { spec in
            AssetContents.Image(
                filename: spec.filename,
                idiom: "mac",
                scale: "\(spec.scale)x",
                size: "\(spec.pointSize)x\(spec.pointSize)"
            )
        },
        info: AssetContents.Info(author: "xcode", version: 1)
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    var data = try encoder.encode(contents)
    data.append(0x0A)
    try data.write(to: directory.appendingPathComponent("Contents.json"), options: .atomic)
}

func installGeneratedDirectory(_ generatedDirectory: URL, at destination: URL) throws {
    let fileManager = FileManager.default
    let backup = destination
        .deletingLastPathComponent()
        .appendingPathComponent(".AppIcon.backup-\(UUID().uuidString)")
    let destinationExists = fileManager.fileExists(atPath: destination.path)

    if destinationExists {
        try fileManager.moveItem(at: destination, to: backup)
    }

    do {
        try fileManager.moveItem(at: generatedDirectory, to: destination)
    } catch {
        if destinationExists {
            do {
                try fileManager.moveItem(at: backup, to: destination)
            } catch let rollbackError {
                throw CocoaError(
                    .fileWriteUnknown,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Icon installation failed: \(error.localizedDescription). Rollback also failed: \(rollbackError.localizedDescription)"
                    ]
                )
            }
        }
        throw error
    }

    if destinationExists {
        try fileManager.removeItem(at: backup)
    }
}

func generateIcons() throws {
    let fileManager = FileManager.default
    let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let projectDirectory = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
    let assetCatalog = projectDirectory.appendingPathComponent("ClamAV-GUI/Resources/Assets.xcassets")
    let destination = assetCatalog.appendingPathComponent("AppIcon.appiconset")
    let temporary = assetCatalog.appendingPathComponent(".AppIcon.generated-\(UUID().uuidString)")

    guard fileManager.fileExists(atPath: assetCatalog.path) else {
        throw CocoaError(
            .fileNoSuchFile,
            userInfo: [NSLocalizedDescriptionKey: "Asset catalog not found: \(assetCatalog.path)"]
        )
    }

    try fileManager.createDirectory(at: temporary, withIntermediateDirectories: false)

    do {
        for spec in iconSpecs {
            let output = temporary.appendingPathComponent(spec.filename)
            let icon = try createShieldIcon(size: CGFloat(spec.pixelSize))
            try savePNG(icon, to: output, pixelSize: spec.pixelSize)
            print("Created \(spec.filename) (\(spec.pixelSize)x\(spec.pixelSize))")
        }

        try writeContents(to: temporary)
        try installGeneratedDirectory(temporary, at: destination)
    } catch {
        if fileManager.fileExists(atPath: temporary.path) {
            do {
                try fileManager.removeItem(at: temporary)
            } catch let cleanupError {
                FileHandle.standardError.write(
                    Data("Warning: could not remove \(temporary.path): \(cleanupError.localizedDescription)\n".utf8)
                )
            }
        }
        throw error
    }

    print("Installed AppIcon.appiconset at \(destination.path)")
}

do {
    try generateIcons()
} catch {
    FileHandle.standardError.write(Data("Icon generation failed: \(error.localizedDescription)\n".utf8))
    exit(EXIT_FAILURE)
}
