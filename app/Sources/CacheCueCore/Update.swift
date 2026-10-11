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

/// Whether a newer release is out. The one thing the app asks the network: the public
/// record of this project's latest release, once a day, sending nothing about the person.
public enum UpdateCheck {
    public struct Release: Equatable {
        public let version: AppVersion
        /// The release's page, where the download is.
        public let page: URL
    }

    public static let repository = "MinLi999/CacheCue"
    public static let endpoint = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    public static let interval: TimeInterval = 24 * 3600

    /// The release GitHub's `releases/latest` answer describes; nil if it is not one.
    public static func release(from data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String, let version = AppVersion(tag),
              let link = json["html_url"] as? String, let page = URL(string: link),
              page.scheme == "https", page.host == "github.com"
        else { return nil }
        return Release(version: version, page: page)
    }

    /// The release to tell the person about: one newer than what is running. A build with
    /// no release version (a local `dev` build) is never told to update.
    public static func update(from data: Data, running current: String) -> Release? {
        guard let running = AppVersion(current), let latest = release(from: data), latest.version > running
        else { return nil }
        return latest
    }

    /// Enough time has passed since the last check to ask again.
    public static func isDue(lastChecked: Date?, now: Date) -> Bool {
        guard let lastChecked else { return true }
        return now.timeIntervalSince(lastChecked) >= interval
    }
}
