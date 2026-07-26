import Foundation
import MiloDomain
import Testing

@Suite("Bounded command output")
struct BoundedCommandOutputTests {
    @Test("stdout and stderr share one exact byte budget")
    func combinedBudget() throws {
        var output = try MiloBoundedCommandOutput(maximumBytes: 6)
        output.append(Data("abcd".utf8), to: .standardOutput)
        output.append(Data("efgh".utf8), to: .standardError)

        #expect(output.standardOutput == Data("abcd".utf8))
        #expect(output.standardError == Data("ef".utf8))
        #expect(output.wasTruncated)
    }

    @Test("an exact-size result is not reported as truncated")
    func exactBudget() throws {
        var output = try MiloBoundedCommandOutput(maximumBytes: 4)
        output.append(Data("test".utf8), to: .standardOutput)

        #expect(output.standardOutput == Data("test".utf8))
        #expect(output.standardError.isEmpty)
        #expect(!output.wasTruncated)
    }

    @Test("nonpositive limits fail closed", arguments: [0, -1])
    func invalidLimit(maximumBytes: Int) {
        #expect(throws: MiloCommandOutputError.invalidMaximumBytes) {
            try MiloBoundedCommandOutput(maximumBytes: maximumBytes)
        }
    }
}
