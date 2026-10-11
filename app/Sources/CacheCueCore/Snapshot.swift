import Foundation

/// One session's figures, as the status line command (terminal) or the cachecue plugin
/// (desktop) last wrote them to `~/Library/Caches/CacheCue/<session_id>.json`.
public struct Snapshot: Codable, Equatable {
    public struct Cache: Codable, Equatable {
        public var turnHit: Int?
        public var avgHit: Int?
        /// Epoch seconds.
        public var expiresAt: Double?
        /// A turn is in flight, so the cache is in use and the countdown is not running.
        public var active: Bool

        enum CodingKeys: String, CodingKey {
            case turnHit = "turn_hit"
            case avgHit = "avg_hit"
            case expiresAt = "expires_at"
            case active
        }
    }

    public struct Limit: Codable, Equatable {
        /// 0 to 100.
        public var used: Double
        /// Epoch seconds.
        public var resetsAt: Double?

        enum CodingKeys: String, CodingKey {
            case used
            case resetsAt = "resets_at"
        }
    }

    public struct Context: Codable, Equatable {
        public var tokens: Double
        public var output: Double
        public var window: Double
        public var percent: Double?
    }

    public static let version = 1

    public var v: Int
    public var source: String
    public var sessionID: String
    public var cwd: String?
    public var cache: Cache
    /// Keyed `five_hour` / `seven_day`; a window with no reading is absent.
    public var limits: [String: Limit]
    /// Epoch seconds when this session received `limits`; nil when it cannot say.
    public var limitsAt: Double?
    public var context: Context
    public var costUSD: Double?
    /// Epoch seconds of the session's last activity: writers rewrite only on a change.
    public var updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case v, source, cwd, cache, limits, context
        case sessionID = "session_id"
        case limitsAt = "limits_at"
        case costUSD = "cost_usd"
        case updatedAt = "updated_at"
    }
}

public enum SnapshotStore {
    public static let retention: TimeInterval = 7 * 24 * 3600

    public static var defaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["CACHECUE_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/CacheCue", isDirectory: true)
    }

    private static func files(in directory: URL) -> [URL] {
        let found = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        return (found ?? []).filter { $0.pathExtension == "json" }
    }

    /// Every snapshot that decodes. A file caught mid-write, or of another version, is
    /// left out for this pass; the next pass reads it again.
    public static func load(from directory: URL) -> [Snapshot] {
        let decoder = JSONDecoder()
        return files(in: directory).compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let snapshot = try? decoder.decode(Snapshot.self, from: data),
                  snapshot.v == Snapshot.version
            else { return nil }
            return snapshot
        }
    }

    /// Removes snapshot files not touched for a week. Returns how many went.
    @discardableResult
    public static func prune(in directory: URL, now: Date) -> Int {
        var removed = 0
        for url in files(in: directory) {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let modified, now.timeIntervalSince(modified) > retention else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil {
                removed += 1
            }
        }
        return removed
    }
}
