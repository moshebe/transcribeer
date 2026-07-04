import Foundation

public enum ChipGeneration: Sendable, Equatable {
    case m1, m2, m3, m4, unknown
}

public enum ChipTier: Sendable, Equatable {
    case air   // base M-series, no Pro/Max/Ultra suffix
    case pro
    case max
    case ultra
    case unknown
}

public struct ChipInfo: Sendable, Equatable {
    public let brand: String
    public let generation: ChipGeneration
    public let tier: ChipTier
}

public enum ChipClassifier {
    /// Reads the actual CPU brand string from sysctl.
    public static func detect() -> ChipInfo {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return ChipInfo(brand: "", generation: .unknown, tier: .unknown) }
        var brand = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &brand, &size, nil, 0)
        let str = String(cString: brand)
        return parse(str)
    }

    /// Pure parsing function — testable without real hardware.
    public static func parse(_ brand: String) -> ChipInfo {
        // Intel CPUs → unknown for both
        guard !brand.contains("Intel") else {
            return ChipInfo(brand: brand, generation: .unknown, tier: .unknown)
        }

        // Empty / unrecognised brand → unknown
        guard !brand.isEmpty else {
            return ChipInfo(brand: brand, generation: .unknown, tier: .unknown)
        }

        // Generation: check most-recent first so "M4" doesn't match inside a
        // hypothetical future "M40" string, and so that we prefer a definitive
        // match over a partial one.
        let generation: ChipGeneration
        if brand.contains("M4") {
            generation = .m4
        } else if brand.contains("M3") {
            generation = .m3
        } else if brand.contains("M2") {
            generation = .m2
        } else if brand.contains("M1") {
            generation = .m1
        } else {
            generation = .unknown
        }

        // No recognised Apple Silicon generation → treat as unknown
        guard generation != .unknown else {
            return ChipInfo(brand: brand, generation: .unknown, tier: .unknown)
        }

        // Tier: check Ultra before Max before Pro to avoid false-positives.
        // Real Apple brand strings are "Apple M2 Ultra", "Apple M2 Max", etc.
        // "Ultra" never contains "Max" as a substring in practice, but we still
        // short-circuit safely by checking Ultra first.
        let tier: ChipTier
        if brand.contains("Ultra") {
            tier = .ultra
        } else if brand.contains("Max") {
            tier = .max
        } else if brand.contains("Pro") {
            tier = .pro
        } else {
            tier = .air
        }

        return ChipInfo(brand: brand, generation: generation, tier: tier)
    }
}
