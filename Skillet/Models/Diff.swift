import Foundation

/// Parsed unified diff, structured for rendering.
struct DiffFile: Identifiable, Hashable, Sendable {
    enum Kind: Sendable { case modified, added, deleted, renamed, binary }

    var path: String
    var kind: Kind
    var hunks: [DiffHunk]

    var id: String { path }
    var additions: Int { hunks.flatMap(\.lines).count { $0.kind == .addition } }
    var deletions: Int { hunks.flatMap(\.lines).count { $0.kind == .deletion } }
}

struct DiffHunk: Identifiable, Hashable, Sendable {
    var header: String
    var lines: [DiffLine]
    var id: String { header + (lines.first?.text ?? "") }
}

struct DiffLine: Identifiable, Hashable, Sendable {
    enum Kind: Sendable { case context, addition, deletion }

    var kind: Kind
    var text: String
    var oldNumber: Int?
    var newNumber: Int?
    var id = UUID()
}

enum DiffParser {
    static func parse(_ unified: String) -> [DiffFile] {
        var files: [DiffFile] = []
        var currentFile: DiffFile?
        var currentHunk: DiffHunk?
        var oldLine = 0
        var newLine = 0

        func closeHunk() {
            if let hunk = currentHunk, currentFile != nil {
                currentFile?.hunks.append(hunk)
            }
            currentHunk = nil
        }

        func closeFile() {
            closeHunk()
            if let file = currentFile {
                files.append(file)
            }
            currentFile = nil
        }

        for rawLine in unified.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)

            if line.hasPrefix("diff --git ") {
                closeFile()
                currentFile = DiffFile(path: pathFromDiffHeader(line), kind: .modified, hunks: [])
            } else if line.hasPrefix("new file mode") {
                currentFile?.kind = .added
            } else if line.hasPrefix("deleted file mode") {
                currentFile?.kind = .deleted
            } else if line.hasPrefix("rename to ") {
                currentFile?.kind = .renamed
                currentFile?.path = String(line.dropFirst("rename to ".count))
            } else if line.hasPrefix("Binary files") {
                currentFile?.kind = .binary
            } else if line.hasPrefix("+++ b/") {
                // Prefer the post-image path when present.
                currentFile?.path = String(line.dropFirst("+++ b/".count))
            } else if line.hasPrefix("@@") {
                closeHunk()
                let numbers = hunkNumbers(line)
                oldLine = numbers.old
                newLine = numbers.new
                currentHunk = DiffHunk(header: line, lines: [])
            } else if currentHunk != nil {
                if line.hasPrefix("+") {
                    currentHunk?.lines.append(DiffLine(
                        kind: .addition, text: String(line.dropFirst()),
                        oldNumber: nil, newNumber: newLine
                    ))
                    newLine += 1
                } else if line.hasPrefix("-") {
                    currentHunk?.lines.append(DiffLine(
                        kind: .deletion, text: String(line.dropFirst()),
                        oldNumber: oldLine, newNumber: nil
                    ))
                    oldLine += 1
                } else if line.hasPrefix("\\") {
                    continue // "\ No newline at end of file"
                } else {
                    currentHunk?.lines.append(DiffLine(
                        kind: .context, text: String(line.dropFirst(min(1, line.count))),
                        oldNumber: oldLine, newNumber: newLine
                    ))
                    oldLine += 1
                    newLine += 1
                }
            }
        }
        closeFile()
        return files
    }

    private static func pathFromDiffHeader(_ line: String) -> String {
        // "diff --git a/<path> b/<path>"
        guard let range = line.range(of: " b/") else { return line }
        return String(line[range.upperBound...])
    }

    private static func hunkNumbers(_ header: String) -> (old: Int, new: Int) {
        // "@@ -12,4 +13,6 @@ context"
        var old = 1
        var new = 1
        let parts = header.split(separator: " ")
        for part in parts {
            if part.hasPrefix("-") {
                old = Int(part.dropFirst().split(separator: ",").first ?? "1") ?? 1
            } else if part.hasPrefix("+") {
                new = Int(part.dropFirst().split(separator: ",").first ?? "1") ?? 1
            }
        }
        return (old, new)
    }
}
