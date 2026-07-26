import Foundation

public enum MiloCommandOutputStream: Sendable {
    case standardOutput
    case standardError
}

public enum MiloCommandOutputError: Error, Equatable, Sendable {
    case invalidMaximumBytes
}

public struct MiloBoundedCommandOutput: Equatable, Sendable {
    public let maximumBytes: Int
    public private(set) var standardOutput = Data()
    public private(set) var standardError = Data()
    public private(set) var wasTruncated = false

    public init(maximumBytes: Int) throws {
        guard maximumBytes > 0 else {
            throw MiloCommandOutputError.invalidMaximumBytes
        }
        self.maximumBytes = maximumBytes
    }

    public mutating func append(_ data: Data, to stream: MiloCommandOutputStream) {
        guard !data.isEmpty else {
            return
        }

        let usedBytes = standardOutput.count + standardError.count
        let remainingBytes = maximumBytes - usedBytes
        guard remainingBytes > 0 else {
            wasTruncated = true
            return
        }

        let acceptedBytes = min(data.count, remainingBytes)
        let acceptedData = data.prefix(acceptedBytes)
        switch stream {
        case .standardOutput:
            standardOutput.append(contentsOf: acceptedData)
        case .standardError:
            standardError.append(contentsOf: acceptedData)
        }
        if acceptedBytes < data.count {
            wasTruncated = true
        }
    }
}
