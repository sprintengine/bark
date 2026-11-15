import Foundation

/// Where downloaded models live and the one rule for deleting them: only ever a folder strictly
/// inside a models folder, after resolving `..` and symbolic links, never the models folder itself.
public enum ModelStorage {
    /// `~/Library/Application Support/Fairspoken/Models/`: models the app downloads itself
    /// (Whisper through WhisperKit). Shared by every build of the app, like FluidAudio's cache,
    /// so a model is downloaded once per Mac.
    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fairspoken", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    /// `target` as an absolute, symlink-free path when it lies strictly inside `root` (also
    /// resolved); nil otherwise. A target that doesn't exist is resolved through its parent.
    public static func contained(_ target: URL, in root: URL) -> URL? {
        guard target.isFileURL, root.isFileURL else { return nil }
        let base = resolve(root).pathComponents
        let resolved = resolve(target)
        let parts = resolved.pathComponents
        guard base.count > 1, parts.count > base.count, Array(parts.prefix(base.count)) == base else { return nil }
        return resolved
    }

    /// Removes `target` if it is strictly inside `root` (see `contained`). Returns false, deleting
    /// nothing, when it isn't; a target that is already gone counts as removed.
    @discardableResult
    public static func removeItem(_ target: URL, inside root: URL, fileManager: FileManager = .default) throws -> Bool {
        guard let safe = contained(target, in: root) else { return false }
        if fileManager.fileExists(atPath: safe.path) || (try? fileManager.destinationOfSymbolicLink(atPath: safe.path)) != nil {
            try fileManager.removeItem(at: safe)
        }
        return true
    }

    /// Allocated size of a folder, 0 when it is missing.
    public static func allocatedSize(of folder: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in e {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    /// Standardised and with symbolic links resolved, for the deepest part that exists (so a
    /// link anywhere on the way is followed even when the leaf is missing).
    private static func resolve(_ url: URL) -> URL {
        let standard = url.standardizedFileURL
        var existing = standard
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            tail.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for part in tail { resolved.appendPathComponent(part) }
        return resolved.standardizedFileURL
    }
}
