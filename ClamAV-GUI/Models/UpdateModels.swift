import Foundation

struct UpdateResult: Equatable {
    let timestamp: Date
    let status: UpdateStatus
    let mainVersion: String?
    let dailyVersion: String?
    let bytecodeVersion: String?
    let message: String

    static func success(main: String?, daily: String?, bytecode: String?) -> UpdateResult {
        UpdateResult(
            timestamp: Date(),
            status: .success,
            mainVersion: main,
            dailyVersion: daily,
            bytecodeVersion: bytecode,
            message: "Signatures updated successfully"
        )
    }

    static func alreadyUpToDate() -> UpdateResult {
        UpdateResult(
            timestamp: Date(),
            status: .upToDate,
            mainVersion: nil,
            dailyVersion: nil,
            bytecodeVersion: nil,
            message: "Signatures are already up to date"
        )
    }

    static func failed(error: String) -> UpdateResult {
        UpdateResult(
            timestamp: Date(),
            status: .failed,
            mainVersion: nil,
            dailyVersion: nil,
            bytecodeVersion: nil,
            message: error
        )
    }

    static func inProgress() -> UpdateResult {
        UpdateResult(
            timestamp: Date(),
            status: .inProgress,
            mainVersion: nil,
            dailyVersion: nil,
            bytecodeVersion: nil,
            message: "Updating signatures..."
        )
    }
}

enum UpdateStatus: String, Equatable {
    case success = "Success"
    case upToDate = "Up to Date"
    case failed = "Failed"
    case inProgress = "Updating..."
}

struct SignatureInfo: Equatable {
    let mainVersion: String
    let dailyVersion: String
    let bytecodeVersion: String
    let lastUpdated: Date?
    let signatureCount: Int?

    static var unknown: SignatureInfo {
        SignatureInfo(
            mainVersion: "Unknown",
            dailyVersion: "Unknown",
            bytecodeVersion: "Unknown",
            lastUpdated: nil,
            signatureCount: nil
        )
    }
}
