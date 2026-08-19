import Foundation
import CryptoKit

struct QuarantinedFile: Identifiable, Codable, Equatable {
    let id: UUID
    let originalPath: String
    let quarantinePath: String
    let threatName: String
    let quarantineDate: Date
    let fileSize: Int64
    let sha256Hash: String

    var originalFileName: String {
        (originalPath as NSString).lastPathComponent
    }

    var originalDirectory: String {
        (originalPath as NSString).deletingLastPathComponent
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: quarantineDate)
    }
}

struct QuarantineMetadata: Codable {
    let version: Int
    var files: [QuarantinedFile]

    static var empty: QuarantineMetadata {
        QuarantineMetadata(version: 1, files: [])
    }
}
