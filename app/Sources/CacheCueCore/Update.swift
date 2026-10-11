import Foundation

/// A release version such as `1.0.3`, compared part by part.
public struct AppVersion: Comparable, Equatable, CustomStringConvertible {
    public let parts: [Int]

    /// Reads `1.0.3` or `v1.0.3`; nil for anything that is not dotted numbers, such as `dev`.
    public init?(_ text: String) {
        let trimmed = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        self.parts = parts.compactMap { $0 }
    }

    public static func < (left: AppVersion, right: AppVersion) -> Bool {
        for index in 0..<max(left.parts.count, right.parts.count) {
            let (a, b) = (index < left.parts.count ? left.parts[index] : 0, index < right.parts.count ? right.parts[index] : 0)
            if a != b { return a < b }
        }
        return false
    }

    public static func == (left: AppVersion, right: AppVersion) -> Bool { !(left < right) && !(right < left) }

    public var description: String { parts.map(String.init).joined(separator: ".") }
}
