import Testing
@testable import TranscribeerApp

struct ChipClassifierTests {
    // MARK: - Helpers

    /// Compact tuple type used by the table-driven test below.
    struct ParseCase: CustomStringConvertible {
        let brand: String
        let expectedGeneration: ChipGeneration
        let expectedTier: ChipTier

        var description: String { brand.isEmpty ? "<empty>" : brand }
    }

    // MARK: - Table-driven parse tests

    static let parseCases: [ParseCase] = [
        ParseCase(brand: "Apple M1", expectedGeneration: .m1, expectedTier: .air),
        ParseCase(brand: "Apple M1 Pro", expectedGeneration: .m1, expectedTier: .pro),
        ParseCase(brand: "Apple M2 Max", expectedGeneration: .m2, expectedTier: .max),
        ParseCase(brand: "Apple M2 Ultra", expectedGeneration: .m2, expectedTier: .ultra),
        ParseCase(brand: "Apple M3", expectedGeneration: .m3, expectedTier: .air),
        ParseCase(brand: "Apple M3 Pro", expectedGeneration: .m3, expectedTier: .pro),
        ParseCase(brand: "Apple M4 Max", expectedGeneration: .m4, expectedTier: .max),
        ParseCase(
            brand: "Intel(R) Core(TM) i9-9980HK CPU @ 2.40GHz",
            expectedGeneration: .unknown,
            expectedTier: .unknown
        ),
        ParseCase(brand: "", expectedGeneration: .unknown, expectedTier: .unknown),
    ]

    @Test("ChipClassifier.parse produces correct generation and tier", arguments: parseCases)
    func parse(testCase: ParseCase) {
        let info = ChipClassifier.parse(testCase.brand)
        #expect(info.generation == testCase.expectedGeneration)
        #expect(info.tier == testCase.expectedTier)
    }

    // MARK: - Brand string preservation

    @Test("parse preserves the original brand string")
    func brandPreserved() {
        let brand = "Apple M3 Pro"
        let info = ChipClassifier.parse(brand)
        #expect(info.brand == brand)
    }

    // MARK: - Ultra is not confused with Max

    @Test("Ultra tier does not fall through to Max")
    func ultraNotMisreadAsMax() {
        let info = ChipClassifier.parse("Apple M2 Ultra")
        #expect(info.tier == .ultra)
    }
}
