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
    case sourceIconMissing(String)
    case sourceIconUnreadable(String)
    case bitmapCreationFailed(Int)
    case graphicsContextUnavailable
    case pngEncodingFailed(String)
    case invalidGeneratedDimensions(path: String, expected: Int, actualWidth: Int, actualHeight: Int)

    var errorDescription: String? {
        switch self {
        case .sourceIconMissing(let path):
            return "Source icon not found at \(path)."
        case .sourceIconUnreadable(let path):
            return "Could not read the source icon at \(path)."
        case .bitmapCreationFailed(let size):
            return "Could not create a \(size)x\(size) bitmap."
        case .graphicsContextUnavailable:
            return "Could not create an AppKit graphics context."
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

func loadSourceIcon(at url: URL) throws -> NSImage {
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw IconGenerationError.sourceIconMissing(url.path)
    }
    guard let image = NSImage(contentsOf: url) else {
        throw IconGenerationError.sourceIconUnreadable(url.path)
    }
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
    let sourceIconURL = projectDirectory.appendingPathComponent("docs/images/safemac-av-logo.png")
    let assetCatalog = projectDirectory.appendingPathComponent("ClamAV-GUI/Resources/Assets.xcassets")
    let destination = assetCatalog.appendingPathComponent("AppIcon.appiconset")
    let temporary = assetCatalog.appendingPathComponent(".AppIcon.generated-\(UUID().uuidString)")

    guard fileManager.fileExists(atPath: assetCatalog.path) else {
        throw CocoaError(
            .fileNoSuchFile,
            userInfo: [NSLocalizedDescriptionKey: "Asset catalog not found: \(assetCatalog.path)"]
        )
    }

    let sourceIcon = try loadSourceIcon(at: sourceIconURL)
    try fileManager.createDirectory(at: temporary, withIntermediateDirectories: false)

    do {
        for spec in iconSpecs {
            let output = temporary.appendingPathComponent(spec.filename)
            try savePNG(sourceIcon, to: output, pixelSize: spec.pixelSize)
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
