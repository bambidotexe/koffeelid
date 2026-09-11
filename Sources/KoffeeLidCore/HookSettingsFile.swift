import Foundation

/// Reading and writing Claude Code's settings.json. Strict on purpose: the file belongs to the user and
/// holds configuration this project knows nothing about, so every ambiguous case is an error, not a guess.
public enum HookSettingsFile {
    public enum Failure: Error, CustomStringConvertible {
        case unreadable(String), unparseable, backupFailed(String), writeFailed(String)
        public var description: String {
            switch self {
            case .unreadable(let why): return "could not read settings: \(why)"
            case .unparseable: return "settings file exists but is not valid JSON; refusing to touch it"
            case .backupFailed(let why): return "could not write a backup: \(why)"
            case .writeFailed(let why): return "could not write settings: \(why)"
            }
        }
    }
    /// nil when the file does not exist; throws when it exists but cannot be read or parsed.
    public static func load(at path: URL) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let data: Data
        do { data = try Data(contentsOf: path) } catch { throw Failure.unreadable(error.localizedDescription) }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw Failure.unparseable }
        return root
    }
    public static func backup(from path: URL, to backupPath: URL) throws {
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        try? FileManager.default.removeItem(at: backupPath)
        do { try FileManager.default.copyItem(at: path, to: backupPath) } catch { throw Failure.backupFailed(error.localizedDescription) }
    }
    public static func write(_ root: [String: Any], to path: URL) throws {
        do {
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: path, options: .atomic)
        } catch { throw Failure.writeFailed(error.localizedDescription) }
    }
}
