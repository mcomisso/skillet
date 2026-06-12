import Foundation

/// A file inside a skill directory, for the detail view's file browser.
struct SkillFile: Identifiable, Hashable, Sendable {
    /// Path relative to the skill directory.
    var relativePath: String
    var url: URL
    var isDirectory: Bool
    var size: Int64

    var id: String { relativePath }
    var name: String { (relativePath as NSString).lastPathComponent }
    var depth: Int { relativePath.count { $0 == "/" } }
}

enum FileTree {
    /// Lists every file under `directory`, sorted so the listing reads like
    /// a tree (directories before their contents).
    static func list(at directory: URL) async -> [SkillFile] {
        let task = Task.detached(priority: .userInitiated) { () -> [SkillFile] in
            listSync(at: directory)
        }
        return await task.value
    }

    private static func listSync(at directory: URL) -> [SkillFile] {
        let fm = FileManager()
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let basePath = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        var files: [SkillFile] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let resolvedPath = url.path
            let relative = resolvedPath.hasPrefix(basePath)
                ? String(resolvedPath.dropFirst(basePath.count))
                : url.lastPathComponent
            files.append(SkillFile(
                relativePath: relative,
                url: url,
                isDirectory: values?.isDirectory ?? false,
                size: Int64(values?.fileSize ?? 0)
            ))
        }
        return files.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }
}
